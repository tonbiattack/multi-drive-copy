[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Preset,
    [string]$SourceListFile,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Sources
)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'MultiDriveCopy.Core.ps1')
# Application state shared by the UI event handlers and copy functions.
$script:settings=Join-Path $env:APPDATA 'MultiDriveCopy\presets.json'
$script:scriptPath=$PSCommandPath
$script:presets=[ordered]@{}
$script:presetDrives=@{}
$script:presetRecycle=@{}
$script:all=$null
$script:cancel=$false
$script:copied=0
$script:skipped=0
$script:total=0
$script:totalWork=0
$script:completedWork=0
$script:sourceFiles=@()
$script:copyMap=$null
$script:copyDirMap=$null
$script:lastPreset=$null
$script:progressBar=$null
$script:statusLabel=$null
$script:copying=$false

function Alert($message) {
    [Windows.Forms.MessageBox]::Show([string]$message, 'Multi Drive Copy', 'OK', 'Error') | Out-Null
}

# Validates the destination entered by the user before a drive root is added.
function Relative($value) {
    $p=([string]$value).Trim().Replace('/','\')
    if($p.StartsWith('\') -or $p -match '^[a-zA-Z]:' -or $p -match '(^|\\)\.\.?($|\\)' -or $p.IndexOfAny([char[]]'<>:"|?*') -ge 0) {throw 'ドライブ文字のない相対パスを入力してください。'}
    return $p.TrimEnd('\')
}
function Persist {
    Save-PresetSettings $script:settings $script:presets $script:lastPreset $script:presetDrives $script:presetRecycle
}
# Rebuilds the "SendTo" shortcuts so direct preset entries stay in sync with saved settings.
function Update-SendToShortcuts {
    try {
        $list=@($script:presets.Keys|ForEach-Object {[pscustomobject]@{name=$_;path=$script:presets[$_];recycle=[bool]$script:presetRecycle[$_]}})
        Sync-PresetSendToShortcuts -TargetScript $script:scriptPath -Presets $list
    } catch {}
}
if(Test-Path -LiteralPath $script:settings) {
    try {
        $saved=Get-PresetSettings $script:settings
        foreach($p in @($saved.presets)){
            if($p.name -and $null -ne $p.path){
                $name=[string]$p.name
                $script:presets[$name]=[string]$p.path
                if($p.drives){$script:presetDrives[$name]=@($p.drives|ForEach-Object {[string]$_})}
                if($p.recycle){$script:presetRecycle[$name]=$true}
            }
        }
        $script:lastPreset=[string]$saved.lastSelectedPreset
    } catch {Alert "保存設定を読めません: $_"}
}
if($script:presets.Count -eq 0){$script:presets['既定 (Backup)']='Backup'}
$manifestSources=@()
if($SourceListFile){
    if($Preset){
        Alert '-Preset と -SourceListFile は同時に指定できません。'
        exit 1
    }
    try{
        $manifestSources=@(Read-SourceListFile $SourceListFile)
    }catch{
        Alert ('ソースリストを読み込めません: '+$_.Exception.Message)
        exit 1
    }
}
try{
    $mergeResult=Merge-SourcePaths -CommandLineSources $Sources -ManifestSources $manifestSources
    $sourceItems=@($mergeResult.Sources)
}catch{
    Alert ('コピー元の検証に失敗しました: '+$_.Exception.Message)
    exit 1
}
if($SourceListFile -and $sourceItems.Count -eq 0){
    Alert 'ソースリストに有効なコピー元がありません。'
    exit 1
}
function Button($text,$x,$y,$w){
    $b=New-Object Windows.Forms.Button
    $b.Text=$text;$b.SetBounds($x,$y,$w,30);return $b
}
# Asks once per collision unless the user chose to apply a choice to all later collisions.
# ZIP collisions default to Skip so an existing archive is never overwritten by accident.
function Conflict($path){
    if($script:all){return $script:all}
    $isZip=Test-ZipFileName ([IO.Path]::GetFileName([string]$path))
    $dlg=New-Object Windows.Forms.Form
    $dlg.Text=if($isZip){'同名のZIPが存在します'}else{'同名ファイルが存在します'}
    $dlg.Size=New-Object Drawing.Size(660,240)
    $dlg.StartPosition='CenterScreen'
    $dlg.FormBorderStyle='FixedDialog'
    $dlg.MaximizeBox=$false
    $label=New-Object Windows.Forms.Label
    $label.Text='競合先: '+$path
    $label.SetBounds(15,15,625,60)
    $label.AutoEllipsis=$true
    $dlg.Controls.Add($label)
    if($isZip){
        $note=New-Object Windows.Forms.Label
        $note.Text='同名ZIPは既定でスキップします。上書き・別名保存は明示的に選んでください。同サイズでも内容が同じとは限りません。'
        $note.SetBounds(15,72,625,34)
        $dlg.Controls.Add($note)
    }
    $all=New-Object Windows.Forms.CheckBox
    $all.Text='以降の競合にも適用する'
    $all.SetBounds(15,110,310,24)
    $dlg.Controls.Add($all)
    $opts=@(@('上書き','Overwrite'),@('スキップ','Skip'),@('別名保存','Rename'),@('中止','Cancel'))
    $skipButton=$null
    for($i=0;$i -lt 4;$i++){
        $btn=Button $opts[$i][0] (15+155*$i) 146 145
        $btn.Tag=$opts[$i][1]
        if($opts[$i][1] -eq 'Skip'){$skipButton=$btn}
        $btn.Add_Click({$dlg.Tag=$this.Tag;$dlg.Close()}.GetNewClosure())
        $dlg.Controls.Add($btn)
    }
    if($isZip -and $skipButton){
        # Enter and the highlighted button both resolve to Skip for ZIPs.
        $dlg.AcceptButton=$skipButton
        $skipButton.Text='スキップ（既定）'
    }
    [void]$dlg.ShowDialog()
    $decision=if($dlg.Tag){[string]$dlg.Tag}else{'Cancel'}
    if($all.Checked -and $decision -ne 'Cancel'){$script:all=$decision}
    $dlg.Dispose()
    return $decision
}
# Finds an unused name while retaining the source extension.
function Unique($path){
    $dir=[IO.Path]::GetDirectoryName($path)
    $base=[IO.Path]::GetFileNameWithoutExtension($path)
    $ext=[IO.Path]::GetExtension($path)
    $n=1
    do{$p=Join-Path $dir ('{0} ({1}){2}' -f $base,$n,$ext);$n++}while([IO.File]::Exists($p) -or [IO.Directory]::Exists($p))
    return $p
}
function Update-CopyProgress([double]$currentWork=0){
    if($script:progressBar){
        $value=if($script:totalWork -gt 0){[Math]::Floor(1000 * [Math]::Min(1.0, ($script:completedWork+$currentWork)/$script:totalWork))}else{0}
        $script:progressBar.Value=[int]$value
        $script:statusLabel.Text='処理済み: '+($script:copied+$script:skipped)+' / '+$script:total+' 件（コピー: '+$script:copied+'、スキップ: '+$script:skipped+'）'
        [Windows.Forms.Application]::DoEvents()
    }
}
# Releases the closing guard before closing the progress form after its result dialog.
function Complete-CopyAndClose([Windows.Forms.Form]$CopyForm){
    $script:copying=$false
    $CopyForm.Close()
}
# Records the real destination used for a source file so verification can follow renames and skips.
function Add-CopyMapping($Source,$Destination,$Action){
    if(-not $script:copyMap){$script:copyMap=New-Object System.Collections.ArrayList}
    [void]$script:copyMap.Add([pscustomobject]@{Source=[string]$Source;Destination=[string]$Destination;Action=[string]$Action})
}
# Records the real destination folder so empty folders and structure can be verified.
function Add-CopyDirMapping($Source,$Destination,$Action){
    if(-not $script:copyDirMap){$script:copyDirMap=New-Object System.Collections.ArrayList}
    [void]$script:copyDirMap.Add([pscustomobject]@{Source=[string]$Source;Destination=[string]$Destination;Action=[string]$Action})
}
# Copies one file and resolves a file or directory collision before writing.
function CopyFile($src,$dest){
    if($script:cancel){return}
    $action='Copied'
    if([IO.File]::Exists($dest) -or [IO.Directory]::Exists($dest)){
        $choice=Conflict $dest
        switch($choice){
            'Skip'{$script:skipped++;$script:completedWork+=([IO.FileInfo]$src).Length+1;Add-CopyMapping $src $dest 'Skipped';Update-CopyProgress;return}
            'Cancel'{$script:cancel=$true;return}
            'Rename'{$dest=Unique $dest;$action='Renamed'}
            'Overwrite'{if([IO.Directory]::Exists($dest)){throw '同名フォルダをファイルで上書きできません: '+$dest};$action='Overwritten'}
        }
    }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($dest)) -Force|Out-Null
    $fileSize=([IO.FileInfo]$src).Length
    Copy-FileWithProgress $src $dest {param($bytes) Update-CopyProgress $bytes}
    $script:copied++
    $script:completedWork+=$fileSize+1
    Add-CopyMapping $src $dest $action
    Update-CopyProgress
}
# Recursively merges a source directory, delegating every file collision to CopyFile.
function CopyDir($src,$dest){
    if($script:cancel){return}
    $action='Created'
    if([IO.File]::Exists($dest)){
        $choice=Conflict $dest
        switch($choice){
            'Skip'{$work=Get-CopyWork @($src);$script:skipped+=$work.Count;$script:completedWork+=$work.Work;Update-CopyProgress;return}
            'Cancel'{$script:cancel=$true;return}
            'Rename'{$dest=Unique $dest;$action='Renamed'}
            'Overwrite'{throw '同名ファイルをフォルダで上書きできません: '+$dest}
        }
    } elseif([IO.Directory]::Exists($dest)){
        $action='Merged'
    }
    New-Item -ItemType Directory -Path $dest -Force|Out-Null
    Add-CopyDirMapping $src $dest $action
    foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($src)){
        if($script:cancel){break}
        $target=Join-Path $dest ([IO.Path]::GetFileName($entry))
        if([IO.Directory]::Exists($entry)){CopyDir $entry $target}
        elseif([IO.File]::Exists($entry)){CopyFile $entry $target}
    }
}
# Runs the copy loop shared by the full UI and the direct preset mode.
function Start-CopyOperation([string[]]$Sources,[string[]]$Destinations){
    $script:all=$null;$script:cancel=$false;$script:copied=0;$script:skipped=0
    $work=Get-CopyWork $Sources
    $script:sourceFiles=@($work.Files)
    $script:copyMap=New-Object System.Collections.ArrayList
    $script:copyDirMap=New-Object System.Collections.ArrayList
    $script:total=$work.Count*$Destinations.Count;$script:totalWork=$work.Work*$Destinations.Count;$script:completedWork=0
    if($script:progressBar){$script:progressBar.Maximum=1000;$script:progressBar.Value=0}
    Update-CopyProgress
    foreach($root in $Destinations){
        foreach($src in $Sources){
            if($script:cancel){break}
            $name=[IO.Path]::GetFileName(([string]$src).TrimEnd('\'))
            $target=Join-Path $root $name
            if([IO.Directory]::Exists([string]$src)){CopyDir ([string]$src) $target}
            else{CopyFile ([string]$src) $target}
        }
        if($script:cancel){break}
    }
    if(!$script:cancel -and $script:totalWork -eq 0 -and $script:progressBar){$script:progressBar.Value=$script:progressBar.Maximum}
}
# Shows a Windows notification and keeps the process alive long enough for it to appear.
function Show-CopyNotification([string]$Title,[string]$Message,[string]$Level='Info'){
    try{
        $notify=New-Object Windows.Forms.NotifyIcon
        $notify.Icon=[Drawing.SystemIcons]::Information
        if($Level -eq 'Warning'){$notify.Icon=[Drawing.SystemIcons]::Warning}
        $notify.Text='Multi Drive Copy'
        $notify.Visible=$true
        $notify.BalloonTipTitle=$Title
        $notify.BalloonTipText=$Message
        $notify.BalloonTipIcon=$Level
        $notify.ShowBalloonTip(4000)
        $until=[DateTime]::UtcNow.AddSeconds(4)
        while([DateTime]::UtcNow -lt $until){[Windows.Forms.Application]::DoEvents();Start-Sleep -Milliseconds 100}
        $notify.Visible=$false
        $notify.Dispose()
    }catch{}
}
function Get-VerificationStatusLabel([string]$Status){
    switch($Status){
        'Verified'{return '検証成功'}
        'Moved'{return 'ごみ箱へ移動済み'}
        'Mismatch'{return '不一致'}
        'Protected'{return '保護'}
        'Changed'{return '変更を検出'}
        'MoveFailed'{return '移動失敗'}
        default{return $Status}
    }
}
function Get-CopyActionLabel([string]$Action){
    switch($Action){
        'Copied'{return 'コピー'}
        'Skipped'{return 'スキップ'}
        'Renamed'{return '別名保存'}
        'Overwritten'{return '上書き'}
        'Created'{return '新規作成'}
        'Merged'{return '統合'}
        default{return $Action}
    }
}
function Format-VerificationDetails([object[]]$Results){
    $items=@($Results)
    $limit=500
    $builder=New-Object System.Text.StringBuilder
    $shown=0
    foreach($result in $items){
        if($shown -ge $limit){break}
        $shown++
        $kindLabel=if($result.Kind -eq 'Folder'){'フォルダ'}else{'ファイル'}
        [void]$builder.AppendLine('['+(Get-VerificationStatusLabel $result.Status)+'] ['+$kindLabel+'] '+$result.Source)
        $actionText=''
        if($result.Action){$actionText=@($result.Action -split ', '|Where-Object {$_}|ForEach-Object {Get-CopyActionLabel $_}) -join ', '}
        [void]$builder.AppendLine('  サイズ: '+(Format-FileSize $result.Size)+' / 操作: '+$actionText)
        if($result.Kind -eq 'Folder'){[void]$builder.AppendLine('  内訳: ファイル '+$result.FileCount+' / ディレクトリ '+$result.DirectoryCount)}
        foreach($destination in @($result.Destinations)){[void]$builder.AppendLine('  コピー先: '+$destination)}
        if($result.Reason){[void]$builder.AppendLine('  詳細: '+$result.Reason)}
        [void]$builder.AppendLine('')
    }
    if($items.Count -gt $limit){[void]$builder.AppendLine('... ほか '+($items.Count-$limit)+' 件。全件はログを参照してください。')}
    return $builder.ToString()
}
# Recomputes verification counts and refreshes the result dialog and log.
function Update-VerificationResultView {
    $summary=Get-VerificationSummary $script:verificationResults
    $text='コピー: '+$script:copied+' 件 / スキップ: '+$script:skipped+' 件'
    $text+=[Environment]::NewLine+'検証成功（ごみ箱へ移動可能）: '+$summary.Verified+' 件 / '+(Format-FileSize $summary.CandidateSize)
    $text+=[Environment]::NewLine+'不一致: '+$summary.Mismatch+' 件 / 保護: '+$summary.Protected+' 件 / 移動済み: '+$summary.Moved+' 件 / 変更: '+$summary.Changed+' 件 / 失敗: '+$summary.Failed+' 件'
    $script:verificationSummaryLabel.Text=$text
    $script:verificationDetail.Text=Format-VerificationDetails $script:verificationResults
    $script:verificationMoveButton.Text='検証済み '+$summary.Verified+' 件をごみ箱へ移動'
    $script:verificationMoveButton.Enabled=($summary.Verified -gt 0)
    try{
        Write-VerificationLog -Path $script:verificationLogPath -Results $script:verificationResults -Summary $summary -FileResults $script:verificationFileResults
        $script:verificationLogLabel.Text='ログ: '+$script:verificationLogPath
    }catch{
        $script:verificationLogLabel.Text='ログを書き込めません: '+$_.Exception.Message
    }
}
function Show-VerificationResult([object[]]$Results,[string]$LogPath,[Windows.Forms.Form]$Owner,[object[]]$FileResults){
    $script:verificationResults=$Results
    $script:verificationFileResults=$FileResults
    $script:verificationLogPath=$LogPath
    $dialog=New-Object Windows.Forms.Form
    $script:verificationDialog=$dialog
    $dialog.Text='コピー結果と検証'
    $dialog.StartPosition='CenterParent'
    $dialog.FormBorderStyle='FixedDialog'
    $dialog.MaximizeBox=$false
    $dialog.MinimizeBox=$false
    $dialog.ControlBox=$false
    $dialog.ClientSize=New-Object Drawing.Size(860,540)
    $script:verificationMoving=$false
    $dialog.Add_FormClosing({if($script:verificationMoving){$_.Cancel=$true}})
    $script:verificationSummaryLabel=New-Object Windows.Forms.Label
    $script:verificationSummaryLabel.SetBounds(15,12,830,58)
    $dialog.Controls.Add($script:verificationSummaryLabel)
    $script:verificationDetail=New-Object Windows.Forms.TextBox
    $script:verificationDetail.Multiline=$true
    $script:verificationDetail.ReadOnly=$true
    $script:verificationDetail.WordWrap=$false
    $script:verificationDetail.ScrollBars='Both'
    $script:verificationDetail.SetBounds(15,74,830,400)
    $dialog.Controls.Add($script:verificationDetail)
    $script:verificationLogLabel=New-Object Windows.Forms.Label
    $script:verificationLogLabel.AutoEllipsis=$true
    $script:verificationLogLabel.SetBounds(15,482,520,22)
    $dialog.Controls.Add($script:verificationLogLabel)
    $script:verificationMoveButton=Button '' 540 478 190
    $script:verificationMoveButton.Height=30
    $dialog.Controls.Add($script:verificationMoveButton)
    $script:verificationCloseButton=Button '閉じる' 740 478 105
    $script:verificationCloseButton.Height=30
    $dialog.Controls.Add($script:verificationCloseButton)
    Update-VerificationResultView
    $script:verificationCloseButton.Add_Click({$script:verificationDialog.Close()})
    $script:verificationMoveButton.Add_Click({
        $summary=Get-VerificationSummary $script:verificationResults
        $candidates=@($script:verificationResults|Where-Object {$_.Status -eq 'Verified'})
        if(-not $candidates.Count){return}
        $preview=@($candidates|Select-Object -First 10|ForEach-Object {$_.Source})
        $previewText=$preview -join [Environment]::NewLine
        if($candidates.Count -gt $preview.Count){$previewText+=[Environment]::NewLine+'ほか '+($candidates.Count-$preview.Count)+' 件'}
        $message='検証済みのコピー元をごみ箱へ移動します。'+[Environment]::NewLine+[Environment]::NewLine+'対象: '+$candidates.Count+' 件 / '+(Format-FileSize $summary.CandidateSize)+[Environment]::NewLine+'移動先: Windowsのごみ箱（完全削除は行いません）'+[Environment]::NewLine+'フォルダの候補は配下の全ファイル・空フォルダを含めて移動します。'+[Environment]::NewLine+[Environment]::NewLine+$previewText
        if([Windows.Forms.MessageBox]::Show($message,'ごみ箱へ移動の最終確認','YesNo','Warning') -ne 'Yes'){return}
        $script:verificationMoving=$true
        $script:verificationDialog.Cursor='WaitCursor'
        $script:verificationMoveButton.Enabled=$false
        $script:verificationCloseButton.Enabled=$false
        $total=$candidates.Count
        try{
            Move-VerifiedItemsToRecycleBin -Results $script:verificationResults -OnProgress {param($i,$path) $script:verificationSummaryLabel.Text='ごみ箱へ移動中: '+$i+' / '+$total+' 件';[Windows.Forms.Application]::DoEvents()}
            $after=Get-VerificationSummary $script:verificationResults
            $resultMessage='ごみ箱への移動結果'+[Environment]::NewLine+'移動: '+$after.Moved+' 件 / 変更を検出: '+$after.Changed+' 件 / 失敗: '+$after.Failed+' 件'+[Environment]::NewLine+[Environment]::NewLine+'詳細はログを参照してください。'+[Environment]::NewLine+$script:verificationLogPath
            [Windows.Forms.MessageBox]::Show($resultMessage,'移動結果','OK','Information')|Out-Null
        }catch{
            [Windows.Forms.MessageBox]::Show('移動処理でエラーが発生しました: '+$_.Exception.Message+'。コピー元は残しています。','移動エラー','OK','Error')|Out-Null
        }finally{
            $script:verificationMoving=$false
            $script:verificationDialog.Cursor='Default'
            $script:verificationCloseButton.Enabled=$true
            Update-VerificationResultView
        }
    })
    if($Owner){[void]$dialog.ShowDialog($Owner)}else{[void]$dialog.ShowDialog()}
    $dialog.Dispose()
    $script:verificationDialog=$null
    $script:verificationResults=$null
    $script:verificationFileResults=$null
}
function Get-PresetDriveLetters([string]$Name){
    if($script:presetDrives.Contains($Name)){
        $stored=@($script:presetDrives[$Name]|Where-Object {$_})
        if($stored.Count){return @($stored)}
    }
    return @('E','F','G')
}
# Verifies every copied source against all destinations and returns the top-level results.
function Get-CopyVerificationResults([string[]]$Sources,[string[]]$Destinations,[scriptblock]$OnStatus){
    $sourceFiles=@($script:sourceFiles)
    $selectedFolders=@($Sources|Where-Object {[IO.Directory]::Exists($_)})
    $fileTotal=[Math]::Max(1,$sourceFiles.Count)
    if($OnStatus){& $OnStatus '検証中...' 0 $fileTotal}
    $fileResults=@(Get-CopyVerification -SourceFiles $sourceFiles -CopyMap @($script:copyMap) -DestinationCount $Destinations.Count -OnProgress {
        param($i,$path)
        if($OnStatus){& $OnStatus ('ファイル検証中: '+$i+' / '+$sourceFiles.Count+' 件') $i $fileTotal}
    })
    $folderResults=@()
    if($selectedFolders.Count){
        if($OnStatus){& $OnStatus 'フォルダ構造を検証中...' 0 ([Math]::Max(1,$selectedFolders.Count))}
        $folderResults=@(Get-FolderVerification -SourceFolders $selectedFolders -FileResults $fileResults -DirectoryMap @($script:copyDirMap) -DestinationCount $Destinations.Count -OnProgress {
            param($i,$path)
            if($OnStatus){& $OnStatus ('フォルダ検証中: '+$i+' / '+$selectedFolders.Count+' 件') $i ([Math]::Max(1,$selectedFolders.Count))}
        })
    }
    $topResults=New-Object System.Collections.ArrayList
    foreach($source in $Sources){
        if([IO.Directory]::Exists($source)){
            $folderResult=@($folderResults|Where-Object {(Get-PathKey ([string]$_.Source)) -eq (Get-PathKey $source)})|Select-Object -First 1
            if($folderResult){[void]$topResults.Add($folderResult)}
        } else {
            $fileResult=@($fileResults|Where-Object {(Get-PathKey ([string]$_.Source)) -eq (Get-PathKey $source)})|Select-Object -First 1
            if($fileResult){[void]$topResults.Add($fileResult)}
        }
    }
    if(Test-SourceOverlap $Sources){
        foreach($item in $topResults){$item.Status='Protected';$item.Reason='コピー元が入れ子または重複しているため移動できません'}
    } elseif(Test-SourceUnderDestination -Sources $Sources -Destinations $Destinations){
        foreach($item in $topResults){$item.Status='Protected';$item.Reason='コピー元とコピー先が親子関係にあるため移動できません'}
    }
    $logPath=Join-Path $env:APPDATA ('MultiDriveCopy\logs\verify-'+(Get-Date -Format 'yyyyMMdd-HHmmss-fff')+'.log')
    return @{ Results=@($topResults); FileResults=$fileResults; LogPath=$logPath }
}
# Copies without showing the settings form; only prompts when a decision is required.
function Invoke-PresetCopy([string]$PresetName,[string[]]$Sources){
    $progressForm=$null
    try{
        if(-not $script:presets.Contains($PresetName)){
            Alert ('プリセットが見つかりません: '+$PresetName+'。「送る」の設定メニューから開き直してください。')
            return
        }
        $selected=@($Sources|Where-Object {$_ -and (Test-Path -LiteralPath $_)}|ForEach-Object {(Get-Item -LiteralPath $_).FullName})
        if(-not $selected.Count){
            Alert 'コピー元がありません。エクスプローラーでファイル・フォルダを選択してから「送る」で実行してください。'
            return
        }
        $relative=Relative ([string]$script:presets[$PresetName])
        $letters=@(Get-PresetDriveLetters $PresetName)
        $available=@();$missing=@()
        foreach($letter in $letters){
            if(Test-Path -LiteralPath ($letter+':\')){$available+=,$letter}else{$missing+=,$letter}
        }
        if($missing.Count){
            $missingText=($missing|ForEach-Object {$_+':'}) -join ', '
            if(-not $available.Count){Alert ('コピー先ドライブが接続されていません: '+$missingText);return}
            $availableText=($available|ForEach-Object {$_+':'}) -join ', '
            $question='次のドライブが接続されていません: '+$missingText+[Environment]::NewLine+'接続済みのドライブ ('+$availableText+') だけにコピーしますか？'
            if([Windows.Forms.MessageBox]::Show($question,'ドライブ未接続','YesNo','Warning') -ne 'Yes'){return}
        }
        $destinations=@(Resolve-CopyDestinations -Sources $selected -RelativePath $relative -DriveLetters $available)
        $missingDirectories=@(Get-MissingDestinationDirectories $destinations)
        # Direct preset runs skip the settings window, so surface duplicates here.
        $check=Get-ZipDuplicateCheck -Sources $selected -Destinations $destinations
        $duplicateCounts=Get-ZipDuplicateCounts @($check.Reports)
        if($missingDirectories.Count -or $duplicateCounts.WithDuplicate -gt 0 -or $duplicateCounts.Unconfirmed -gt 0){
            $question='コピー元: '+$selected.Count+' 項目'+[Environment]::NewLine+'コピー先: '+($destinations -join ', ')
            if($missingDirectories.Count){$question+=[Environment]::NewLine+'新規作成するフォルダ:'+[Environment]::NewLine+($missingDirectories -join [Environment]::NewLine)}
            if($duplicateCounts.WithDuplicate -gt 0){
                $question+=[Environment]::NewLine+[Environment]::NewLine+'同名ZIPが '+$duplicateCounts.WithDuplicate+' 件あります。既定ではスキップし、上書きはしません。'
                $question+=[Environment]::NewLine+[Environment]::NewLine+(Format-ZipDuplicateDetails @($check.Reports))
            }
            if($duplicateCounts.Unconfirmed -gt 0){
                $question+=[Environment]::NewLine+'同名ZIPを確認できないコピー先が '+$duplicateCounts.Unconfirmed+' 件あります（未確認）。'
            }
            $question+=[Environment]::NewLine+[Environment]::NewLine+'コピーしますか？'
            if([Windows.Forms.MessageBox]::Show($question,'実行確認','YesNo','Question') -ne 'Yes'){return}
        }
        foreach($directory in $missingDirectories){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
        $progressForm=New-Object Windows.Forms.Form
        $progressForm.Text='Multi Drive Copy - '+$PresetName
        $progressForm.StartPosition='CenterScreen'
        $progressForm.FormBorderStyle='FixedDialog'
        $progressForm.MaximizeBox=$false
        $progressForm.MinimizeBox=$false
        $progressForm.ControlBox=$false
        $progressForm.ClientSize=New-Object Drawing.Size(560,190)
        $progressForm.Add_FormClosing({if($script:copying){$_.Cancel=$true}})
        $preview=@($selected|Select-Object -First 2|ForEach-Object {[IO.Path]::GetFileName($_)})
        $sourceText=$preview -join ', '
        if($selected.Count -gt $preview.Count){$sourceText+=' ほか'+($selected.Count-$preview.Count)+' 件'}
        $info=New-Object Windows.Forms.Label
        $info.Text='コピー元 ('+$selected.Count+' 項目): '+$sourceText+[Environment]::NewLine+'コピー先: '+($destinations -join ', ')
        $info.AutoEllipsis=$true
        $info.SetBounds(15,12,530,42)
        $progressForm.Controls.Add($info)
        $script:statusLabel=New-Object Windows.Forms.Label
        $script:statusLabel.Text='準備中...'
        $script:statusLabel.SetBounds(15,58,530,22)
        $progressForm.Controls.Add($script:statusLabel)
        $script:progressBar=New-Object Windows.Forms.ProgressBar
        $script:progressBar.SetBounds(15,86,530,18)
        $script:progressBar.Minimum=0
        $script:progressBar.Maximum=1000
        $progressForm.Controls.Add($script:progressBar)
        $cancelButton=Button 'キャンセル' 415 125 130
        $cancelButton.Add_Click({$script:cancel=$true;$this.Enabled=$false;$this.Text='中止しています...'})
        $progressForm.Controls.Add($cancelButton)
        $script:copying=$true
        $progressForm.Show()
        [Windows.Forms.Application]::DoEvents()
        Start-CopyOperation -Sources $selected -Destinations $destinations
        $recycle=[bool]$script:presetRecycle[$PresetName]
        if($recycle -and -not $script:cancel){
            $verification=Get-CopyVerificationResults -Sources $selected -Destinations $destinations -OnStatus {
                param($text,$i,$total)
                $script:statusLabel.Text=$text
                if($total -gt 0 -and $script:progressBar){
                    $script:progressBar.Maximum=$total
                    $script:progressBar.Value=[Math]::Min($total,$i)
                }
                [Windows.Forms.Application]::DoEvents()
            }
            $summary=Get-VerificationSummary @($verification.Results)
            $script:statusLabel.Text='検証成功: '+$summary.Verified+' 件 / 不一致: '+$summary.Mismatch+' 件 / 保護: '+$summary.Protected+' 件'
            if($script:progressBar){$script:progressBar.Value=$script:progressBar.Maximum}
            [Windows.Forms.Application]::DoEvents()
            Show-VerificationResult -Results @($verification.Results) -LogPath $verification.LogPath -Owner $progressForm -FileResults @($verification.FileResults)
        }
        $script:copying=$false
        $progressForm.Close()
        $progressForm.Dispose()
        $progressForm=$null
        $summary='コピー: '+$script:copied+' 件 / スキップ: '+$script:skipped+' 件'
        if($duplicateCounts.WithDuplicate -gt 0){$summary+=' / 同名ZIP: '+$duplicateCounts.WithDuplicate+' 件'}
        if($script:cancel){Show-CopyNotification 'コピーを中止しました' $summary 'Warning'}
        elseif($recycle){Show-CopyNotification 'コピーと検証が完了しました' $summary 'Info'}
        else{Show-CopyNotification 'コピーが完了しました' $summary 'Info'}
    }catch{
        if($progressForm){$script:copying=$false;$progressForm.Close();$progressForm.Dispose()}
        Alert ('コピーエラー: '+$_.Exception.Message+' （途中までコピーされている場合があります）')
    }
}
if($Preset){
    Invoke-PresetCopy $Preset $sourceItems
    return
}
$form=New-Object Windows.Forms.Form
$form.Text='Multi Drive Copy - E / F / G'
if($SourceListFile){$form.Text='Multi Drive Copy - ソースリスト確認'}
$form.StartPosition='CenterScreen'
$form.Size=New-Object Drawing.Size(720,640)
$form.KeyPreview=$true
$form.Add_FormClosing({if($script:copying){$_.Cancel=$true}})
$label=New-Object Windows.Forms.Label
if($SourceListFile){$label.Text='コピー元（外部アプリから受け取ったソースリスト）'}
else{$label.Text='コピー元（右クリック → 送る で選んだ項目）'}
$label.SetBounds(15,15,670,22)
$form.Controls.Add($label)
$list=New-Object Windows.Forms.ListView
$list.SetBounds(15,42,670,155)
$list.View='Details'
$list.FullRowSelect=$true
$list.MultiSelect=$false
$list.HideSelection=$false
$list.HeaderStyle='Nonclickable'
[void]$list.Columns.Add('コピー元', 430)
[void]$list.Columns.Add('同名ZIP', 210)
foreach($src in $sourceItems){
    $row=New-Object Windows.Forms.ListViewItem([string]$src)
    [void]$row.SubItems.Add('—')
    [void]$list.Items.Add($row)
}
$form.Controls.Add($list)
$checkButton=Button '同名ZIPを確認' 15 200 150
$checkButton.Height=26
$form.Controls.Add($checkButton)
$duplicateLabel=New-Object Windows.Forms.Label
$duplicateLabel.Text='コピー先を決めてから「同名ZIPを確認」を押すと、既存ZIPとの重複を表示します。'
$duplicateLabel.AutoEllipsis=$true
$duplicateLabel.SetBounds(175,203,510,22)
$form.Controls.Add($duplicateLabel)
$label2=New-Object Windows.Forms.Label
$label2.Text='保存済みコピー先パターン'
$label2.SetBounds(15,240,300,22)
$form.Controls.Add($label2)
$combo=New-Object Windows.Forms.ComboBox
$combo.DropDownStyle='DropDownList'
$combo.SetBounds(15,267,320,28)
foreach($name in $script:presets.Keys){[void]$combo.Items.Add($name)}
$form.Controls.Add($combo)
$save=Button 'パターン保存' 350 265 140
$remove=Button 'パターン削除' 500 265 140
$form.Controls.Add($save);$form.Controls.Add($remove)
$label3=New-Object Windows.Forms.Label
$label3.Text='コピー先の共通相対パス（例: Backup\Photos）'
$label3.SetBounds(15,312,670,24)
$form.Controls.Add($label3)
$pathbox=New-Object Windows.Forms.TextBox
$pathbox.SetBounds(15,340,670,27)
$form.Controls.Add($pathbox)
$drives=@()
for($i=0;$i -lt 3;$i++){
    $letter=@('E','F','G')[$i]
    $cb=New-Object Windows.Forms.CheckBox
    $cb.Text=$letter+':\'
    $cb.Tag=$letter
    $cb.Checked=$true
    $cb.SetBounds((15+105*$i),402,95,25)
    $drives+=,$cb
    $form.Controls.Add($cb)
}
$recycle=New-Object Windows.Forms.CheckBox
$recycle.Text='コピー後、検証済みの元データをごみ箱へ移動（パターン保存時に記録し、「送る」から1回で実行できます）'
$recycle.SetBounds(15,430,670,25)
$recycle.Checked=$false
$form.Controls.Add($recycle)
$status=New-Object Windows.Forms.Label
$status.Text='既存フォルダは統合、同名ファイルは確認します。'
if($SourceListFile){
    $status.Text='コピー元を '+$sourceItems.Count+' 件読み込みました。内容を確認してコピーしてください。'
    if($mergeResult.Duplicates -gt 0){$status.Text+='（重複 '+$mergeResult.Duplicates+' 件を除外）'}
}
$status.SetBounds(15,460,670,30)
$form.Controls.Add($status)
$script:statusLabel=$status
$progress=New-Object Windows.Forms.ProgressBar
$progress.SetBounds(15,493,440,18)
$progress.Minimum=0;$progress.Maximum=1;$progress.Value=0
$form.Controls.Add($progress)
$script:progressBar=$progress
$copy=Button 'コピー開始' 475 495 210
$copy.Height=36
$form.Controls.Add($copy)
$combo.Add_SelectedIndexChanged({
    $name=[string]$combo.SelectedItem
    if($script:presets.Contains($name)){
        $pathbox.Text=[string]$script:presets[$name]
        $script:lastPreset=$name
        $stored=@()
        if($script:presetDrives.Contains($name)){$stored=@($script:presetDrives[$name])}
        foreach($cb in $drives){$cb.Checked=($stored.Count -eq 0 -or $stored -contains $cb.Tag)}
        $recycle.Checked=[bool]$script:presetRecycle[$name]
        Persist
    }
})
# Resolves the current copy plan and refreshes the per-source duplicate status.
# Returns $null when the plan is invalid so the caller can show the reason.
function Update-ZipDuplicateView {
    try{
        $relative=Relative $pathbox.Text
        $letters=@($drives|Where-Object {$_.Checked}|ForEach-Object {[string]$_.Tag})
        $sources=@($list.Items|ForEach-Object {[string]$_.Text})
        $destinations=@(Resolve-CopyDestinations -Sources $sources -RelativePath $relative -DriveLetters $letters)
    }catch{
        $duplicateLabel.Text='同名ZIPを確認できません: '+$_.Exception.Message
        return $null
    }
    $check=Get-ZipDuplicateCheck -Sources $sources -Destinations $destinations
    # Reports are keyed by ZIP path, which may sit inside a selected folder, so
    # aggregate every report under each row's source path.
    $reports=@($check.Reports)
    foreach($item in $list.Items){
        $sourceKey=([string]$item.Text).TrimEnd('\').ToLowerInvariant()
        $prefix=$sourceKey+'\'
        $owned=@($reports|Where-Object {
            $key=([string]$_.Source).ToLowerInvariant()
            $key -eq $sourceKey -or $key.StartsWith($prefix)
        })
        $text='—'
        if($owned.Count){
            $counts=Get-ZipDuplicateCounts $owned
            if($counts.WithDuplicate -gt 0){
                $text=Format-ZipDuplicateSummary $owned[0]
                if($counts.WithDuplicate -gt 1){$text='同名ZIP: あり（'+$counts.WithDuplicate+' 件）'}
                $item.ForeColor=[Drawing.Color]::FromArgb(180,60,0)
            } elseif($counts.Unconfirmed -gt 0){
                $text=Format-ZipDuplicateSummary $owned[0]
                $item.ForeColor=[Drawing.Color]::FromArgb(150,110,0)
            } else {
                $text='同名ZIP: なし'
                $item.ForeColor=[Drawing.Color]::FromArgb(0,110,0)
            }
        } else {
            $item.ForeColor=[Drawing.SystemColors]::WindowText
        }
        $item.SubItems[1].Text=$text
    }
    $counts=Get-ZipDuplicateCounts $reports
    if($counts.Total -eq 0){
        $duplicateLabel.Text='コピー対象にZIPはありません。'
    } elseif($counts.WithDuplicate -gt 0){
        $duplicateLabel.Text='同名ZIPあり: '+$counts.WithDuplicate+' 件（既定でスキップします）'
    } elseif($counts.Unconfirmed -gt 0){
        $duplicateLabel.Text='同名ZIP: 未確認 '+$counts.Unconfirmed+' 件（コピー先を読み取れません）'
    } else {
        $duplicateLabel.Text='同名ZIP: なし（'+$counts.Total+' 件のZIPを確認）'
    }
    return $check
}
$checkButton.Add_Click({
    try{
        $check=Update-ZipDuplicateView
        if($null -eq $check){return}
        $details=Format-ZipDuplicateDetails @($check.Reports)
        if(-not $details){
            [Windows.Forms.MessageBox]::Show('コピー先に同名のZIPはありません。','同名ZIPの確認','OK','Information')|Out-Null
            return
        }
        [Windows.Forms.MessageBox]::Show($details,'同名ZIPの確認','OK','Warning')|Out-Null
    }catch{Alert $_.Exception.Message}
})
# Refresh the duplicate column whenever the copy plan changes, so the list is
# already accurate before the user presses コピー開始.
$refreshDuplicates={
    try{ [void](Update-ZipDuplicateView) }catch{}
}
foreach($cb in $drives){$cb.Add_CheckedChanged($refreshDuplicates)}
$pathbox.Add_Leave($refreshDuplicates)
$form.Add_Shown($refreshDuplicates)
$save.Add_Click({
    try{
        $p=Relative $pathbox.Text
        $name=[Microsoft.VisualBasic.Interaction]::InputBox('パターン名','コピー先を保存',[string]$combo.Text).Trim()
        if(!$name){return}
        if($name -match '[\r\n"]'){throw 'パターン名に引用符や改行は使用できません。'}
        $script:presets[$name]=$p
        $checked=@($drives|Where-Object {$_.Checked}|ForEach-Object {[string]$_.Tag})
        if($checked.Count){$script:presetDrives[$name]=$checked}else{$script:presetDrives.Remove($name)}
        if($recycle.Checked){$script:presetRecycle[$name]=$true}else{$script:presetRecycle.Remove($name)}
        Persist
        Update-SendToShortcuts
        if(!$combo.Items.Contains($name)){[void]$combo.Items.Add($name)}
        $combo.SelectedItem=$name
    }catch{Alert $_.Exception.Message}
})
$remove.Add_Click({
    $name=[string]$combo.SelectedItem
    if(!$name){return}
    if([Windows.Forms.MessageBox]::Show("パターン '$name' を削除しますか？",'確認','YesNo','Question') -ne 'Yes'){return}
    $script:presets.Remove($name)
    $script:presetDrives.Remove($name)
    $script:presetRecycle.Remove($name)
    Persist
    Update-SendToShortcuts
    $combo.Items.Remove($name)
    if($combo.Items.Count){$combo.SelectedIndex=0}else{$pathbox.Clear()}
})
$copy.Add_Click({
    try{
        if(!$list.Items.Count){throw 'コピー元がありません。「送る」から起動してください。'}
        $relative=Relative $pathbox.Text
        $letters=@($drives|Where-Object {$_.Checked}|ForEach-Object {[string]$_.Tag})
        $sources=@($list.Items|ForEach-Object {[string]$_.Text})
        $destinations=@(Resolve-CopyDestinations -Sources $sources -RelativePath $relative -DriveLetters $letters)
        $missingDirectories=@(Get-MissingDestinationDirectories $destinations)
        # Re-check right before copying so a ZIP created after the earlier check
        # cannot be overwritten without the user seeing it.
        $check=Get-ZipDuplicateCheck -Sources $sources -Destinations $destinations
        $duplicateCounts=Get-ZipDuplicateCounts @($check.Reports)
        $question='コピー元: '+$list.Items.Count+' 項目'+[Environment]::NewLine+'コピー先: '+($destinations -join ', ')+[Environment]::NewLine+'コピーしますか？'
        if($missingDirectories.Count){$question+=[Environment]::NewLine+'新規作成するフォルダ:'+[Environment]::NewLine+($missingDirectories -join [Environment]::NewLine)}
        if($duplicateCounts.WithDuplicate -gt 0){
            $question+=[Environment]::NewLine+[Environment]::NewLine+'同名ZIPが '+$duplicateCounts.WithDuplicate+' 件あります。既定ではスキップし、上書きはしません。'
            $question+=[Environment]::NewLine+[Environment]::NewLine+(Format-ZipDuplicateDetails @($check.Reports))
        }
        if($duplicateCounts.Unconfirmed -gt 0){
            $question+=[Environment]::NewLine+'同名ZIPを確認できないコピー先が '+$duplicateCounts.Unconfirmed+' 件あります（未確認）。'
        }
        if($recycle.Checked){$question+=[Environment]::NewLine+'コピー後にSHA-256で検証し、確認のうえ検証済みの元データをごみ箱へ移動します。'}
        if([Windows.Forms.MessageBox]::Show($question,'実行確認','YesNo','Question') -ne 'Yes'){return}
        foreach($directory in $missingDirectories){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
        $script:copying=$true
        foreach($control in @($list,$combo,$save,$remove,$pathbox,$copy,$recycle,$checkButton)+$drives){$control.Enabled=$false}
        $form.Cursor='WaitCursor'
        Start-CopyOperation -Sources $sources -Destinations $destinations
        if($recycle.Checked -and -not $script:cancel){
            $sourceFiles=@($script:sourceFiles)
            $status.Text='検証中...'
            $progress.Maximum=[Math]::Max(1,$sourceFiles.Count)
            $progress.Value=0
            [Windows.Forms.Application]::DoEvents()
            $verification=Get-CopyVerificationResults -Sources $sources -Destinations $destinations -OnStatus {
                param($text,$i,$total)
                $status.Text=$text
                if($total -gt 0){$progress.Maximum=$total;$progress.Value=[Math]::Min($total,$i)}
                [Windows.Forms.Application]::DoEvents()
            }
            $results=@($verification.Results)
            $fileResults=@($verification.FileResults)
            $logPath=$verification.LogPath
            $summary=Get-VerificationSummary $results
            $status.Text='検証成功: '+$summary.Verified+' 件 / 不一致: '+$summary.Mismatch+' 件 / 保護: '+$summary.Protected+' 件'
            $progress.Value=$progress.Maximum
            Show-VerificationResult -Results $results -LogPath $logPath -Owner $form -FileResults $fileResults
            Complete-CopyAndClose $form
        } else {
            $status.Text='コピー: '+$script:copied+' 件 / スキップ: '+$script:skipped+' 件'
            $heading=if($script:cancel){'処理を中止しました。'}else{'コピーが完了しました。'}
            $resultText=$heading+' '+$status.Text
            if($duplicateCounts.WithDuplicate -gt 0){
                $resultText+=[Environment]::NewLine+[Environment]::NewLine+'同名ZIPが '+$duplicateCounts.WithDuplicate+' 件あったため、既存ファイルは上書きせずスキップしました。'
            }
            if($duplicateCounts.Unconfirmed -gt 0){
                $resultText+=[Environment]::NewLine+'同名ZIPを確認できなかったコピー先が '+$duplicateCounts.Unconfirmed+' 件あります（未確認）。'
            }
            [Windows.Forms.MessageBox]::Show($resultText,'結果','OK','Information')|Out-Null
            Complete-CopyAndClose $form
        }
    }catch{Alert ('コピーエラー: '+$_.Exception.Message+' （途中までコピーされている場合があります）')}
    finally{$script:copying=$false;foreach($control in @($list,$combo,$save,$remove,$pathbox,$copy,$recycle,$checkButton)+$drives){$control.Enabled=$true};$form.Cursor='Default'}
})
$form.Add_KeyDown({
    if($_.Control -and $_.KeyCode -eq 'Enter'){$copy.PerformClick()}
    elseif($_.Alt -and $_.KeyCode -eq 'S'){$save.PerformClick()}
    elseif($_.Alt -and $_.KeyCode -eq 'D'){$remove.PerformClick()}
})
if($script:lastPreset -and $combo.Items.Contains($script:lastPreset)){$combo.SelectedItem=$script:lastPreset}else{$combo.SelectedIndex=0}
[void]$form.ShowDialog()
