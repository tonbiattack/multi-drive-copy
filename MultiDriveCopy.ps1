[CmdletBinding(PositionalBinding=$false)]
param(
    [string]$Preset,
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
$script:all=$null
$script:cancel=$false
$script:copied=0
$script:skipped=0
$script:total=0
$script:totalWork=0
$script:completedWork=0
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
    Save-PresetSettings $script:settings $script:presets $script:lastPreset $script:presetDrives
}
# Rebuilds the "SendTo" shortcuts so direct preset entries stay in sync with saved settings.
function Update-SendToShortcuts {
    try {
        $list=@($script:presets.Keys|ForEach-Object {[pscustomobject]@{name=$_;path=$script:presets[$_]}})
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
            }
        }
        $script:lastPreset=[string]$saved.lastSelectedPreset
    } catch {Alert "保存設定を読めません: $_"}
}
if($script:presets.Count -eq 0){$script:presets['既定 (Backup)']='Backup'}
function Button($text,$x,$y,$w){
    $b=New-Object Windows.Forms.Button
    $b.Text=$text;$b.SetBounds($x,$y,$w,30);return $b
}
# Asks once per collision unless the user chose to apply a choice to all later collisions.
function Conflict($path){
    if($script:all){return $script:all}
    $dlg=New-Object Windows.Forms.Form
    $dlg.Text='同名ファイルが存在します'
    $dlg.Size=New-Object Drawing.Size(660,210)
    $dlg.StartPosition='CenterScreen'
    $dlg.FormBorderStyle='FixedDialog'
    $dlg.MaximizeBox=$false
    $label=New-Object Windows.Forms.Label
    $label.Text='競合先: '+$path
    $label.SetBounds(15,15,625,60)
    $label.AutoEllipsis=$true
    $dlg.Controls.Add($label)
    $all=New-Object Windows.Forms.CheckBox
    $all.Text='以降の競合にも適用する'
    $all.SetBounds(15,80,310,24)
    $dlg.Controls.Add($all)
    $opts=@(@('上書き','Overwrite'),@('スキップ','Skip'),@('別名保存','Rename'),@('中止','Cancel'))
    for($i=0;$i -lt 4;$i++){
        $btn=Button $opts[$i][0] (15+155*$i) 116 145
        $btn.Tag=$opts[$i][1]
        $btn.Add_Click({$dlg.Tag=$this.Tag;$dlg.Close()}.GetNewClosure())
        $dlg.Controls.Add($btn)
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
# Copies one file and resolves a file or directory collision before writing.
function CopyFile($src,$dest){
    if($script:cancel){return}
    if([IO.File]::Exists($dest) -or [IO.Directory]::Exists($dest)){
        $choice=Conflict $dest
        switch($choice){
            'Skip'{$script:skipped++;$script:completedWork+=([IO.FileInfo]$src).Length+1;Update-CopyProgress;return}
            'Cancel'{$script:cancel=$true;return}
            'Rename'{$dest=Unique $dest}
            'Overwrite'{if([IO.Directory]::Exists($dest)){throw '同名フォルダをファイルで上書きできません: '+$dest}}
        }
    }
    New-Item -ItemType Directory -Path ([IO.Path]::GetDirectoryName($dest)) -Force|Out-Null
    $fileSize=([IO.FileInfo]$src).Length
    Copy-FileWithProgress $src $dest {param($bytes) Update-CopyProgress $bytes}
    $script:copied++
    $script:completedWork+=$fileSize+1
    Update-CopyProgress
}
# Recursively merges a source directory, delegating every file collision to CopyFile.
function CopyDir($src,$dest){
    if($script:cancel){return}
    if([IO.File]::Exists($dest)){
        $choice=Conflict $dest
        switch($choice){
            'Skip'{$work=Get-CopyWork @($src);$script:skipped+=$work.Count;$script:completedWork+=$work.Work;Update-CopyProgress;return}
            'Cancel'{$script:cancel=$true;return}
            'Rename'{$dest=Unique $dest}
            'Overwrite'{throw '同名ファイルをフォルダで上書きできません: '+$dest}
        }
    }
    New-Item -ItemType Directory -Path $dest -Force|Out-Null
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
function Get-PresetDriveLetters([string]$Name){
    if($script:presetDrives.Contains($Name)){
        $stored=@($script:presetDrives[$Name]|Where-Object {$_})
        if($stored.Count){return @($stored)}
    }
    return @('E','F','G')
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
        if($missingDirectories.Count){
            $question='コピー元: '+$selected.Count+' 項目'+[Environment]::NewLine+'コピー先: '+($destinations -join ', ')+[Environment]::NewLine+'新規作成するフォルダ:'+[Environment]::NewLine+($missingDirectories -join [Environment]::NewLine)+[Environment]::NewLine+'コピーしますか？'
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
        $script:copying=$false
        $progressForm.Close()
        $progressForm.Dispose()
        $progressForm=$null
        $summary='コピー: '+$script:copied+' 件 / スキップ: '+$script:skipped+' 件'
        if($script:cancel){Show-CopyNotification 'コピーを中止しました' $summary 'Warning'}
        else{Show-CopyNotification 'コピーが完了しました' $summary 'Info'}
    }catch{
        if($progressForm){$script:copying=$false;$progressForm.Close();$progressForm.Dispose()}
        Alert ('コピーエラー: '+$_.Exception.Message+' （途中までコピーされている場合があります）')
    }
}
if($Preset){
    Invoke-PresetCopy $Preset $Sources
    return
}
$form=New-Object Windows.Forms.Form
$form.Text='Multi Drive Copy - E / F / G'
$form.StartPosition='CenterScreen'
$form.Size=New-Object Drawing.Size(720,555)
$form.KeyPreview=$true
$form.Add_FormClosing({if($script:copying){$_.Cancel=$true}})
$label=New-Object Windows.Forms.Label
$label.Text='コピー元（右クリック → 送る で選んだ項目）'
$label.SetBounds(15,15,670,22)
$form.Controls.Add($label)
$list=New-Object Windows.Forms.ListBox
$list.SetBounds(15,42,670,155)
$list.HorizontalScrollbar=$true
foreach($src in $Sources){if(Test-Path -LiteralPath $src){[void]$list.Items.Add((Get-Item -LiteralPath $src).FullName)}}
$form.Controls.Add($list)
$label2=New-Object Windows.Forms.Label
$label2.Text='保存済みコピー先パターン'
$label2.SetBounds(15,215,300,22)
$form.Controls.Add($label2)
$combo=New-Object Windows.Forms.ComboBox
$combo.DropDownStyle='DropDownList'
$combo.SetBounds(15,242,320,28)
foreach($name in $script:presets.Keys){[void]$combo.Items.Add($name)}
$form.Controls.Add($combo)
$save=Button 'パターン保存' 350 240 140
$remove=Button 'パターン削除' 500 240 140
$form.Controls.Add($save);$form.Controls.Add($remove)
$label3=New-Object Windows.Forms.Label
$label3.Text='コピー先の共通相対パス（例: Backup\Photos）'
$label3.SetBounds(15,287,670,24)
$form.Controls.Add($label3)
$pathbox=New-Object Windows.Forms.TextBox
$pathbox.SetBounds(15,315,670,27)
$form.Controls.Add($pathbox)
$drives=@()
for($i=0;$i -lt 3;$i++){
    $letter=@('E','F','G')[$i]
    $cb=New-Object Windows.Forms.CheckBox
    $cb.Text=$letter+':\'
    $cb.Tag=$letter
    $cb.Checked=$true
    $cb.SetBounds((15+105*$i),377,95,25)
    $drives+=,$cb
    $form.Controls.Add($cb)
}
$status=New-Object Windows.Forms.Label
$status.Text='既存フォルダは統合、同名ファイルは確認します。'
$status.SetBounds(15,412,670,30)
$form.Controls.Add($status)
$script:statusLabel=$status
$progress=New-Object Windows.Forms.ProgressBar
$progress.SetBounds(15,442,440,18)
$progress.Minimum=0;$progress.Maximum=1;$progress.Value=0
$form.Controls.Add($progress)
$script:progressBar=$progress
$copy=Button 'コピー開始' 475 453 210
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
        Persist
    }
})
$save.Add_Click({
    try{
        $p=Relative $pathbox.Text
        $name=[Microsoft.VisualBasic.Interaction]::InputBox('パターン名','コピー先を保存',[string]$combo.Text).Trim()
        if(!$name){return}
        if($name -match '[\r\n"]'){throw 'パターン名に引用符や改行は使用できません。'}
        $script:presets[$name]=$p
        $checked=@($drives|Where-Object {$_.Checked}|ForEach-Object {[string]$_.Tag})
        if($checked.Count){$script:presetDrives[$name]=$checked}else{$script:presetDrives.Remove($name)}
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
        $sources=@($list.Items|ForEach-Object {[string]$_})
        $destinations=@(Resolve-CopyDestinations -Sources $sources -RelativePath $relative -DriveLetters $letters)
        $missingDirectories=@(Get-MissingDestinationDirectories $destinations)
        $question='コピー元: '+$list.Items.Count+' 項目'+[Environment]::NewLine+'コピー先: '+($destinations -join ', ')+[Environment]::NewLine+'コピーしますか？'
        if($missingDirectories.Count){$question+=[Environment]::NewLine+'新規作成するフォルダ:'+[Environment]::NewLine+($missingDirectories -join [Environment]::NewLine)}
        if([Windows.Forms.MessageBox]::Show($question,'実行確認','YesNo','Question') -ne 'Yes'){return}
        foreach($directory in $missingDirectories){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
        $script:copying=$true
        foreach($control in @($list,$combo,$save,$remove,$pathbox,$copy)+$drives){$control.Enabled=$false}
        $form.Cursor='WaitCursor'
        Start-CopyOperation -Sources $sources -Destinations $destinations
        $status.Text='コピー: '+$script:copied+' 件 / スキップ: '+$script:skipped+' 件'
        $heading=if($script:cancel){'処理を中止しました。'}else{'コピーが完了しました。'}
        [Windows.Forms.MessageBox]::Show($heading+' '+$status.Text,'結果','OK','Information')|Out-Null
        Complete-CopyAndClose $form
    }catch{Alert ('コピーエラー: '+$_.Exception.Message+' （途中までコピーされている場合があります）')}
    finally{$script:copying=$false;foreach($control in @($list,$combo,$save,$remove,$pathbox,$copy)+$drives){$control.Enabled=$true};$form.Cursor='Default'}
})
$form.Add_KeyDown({
    if($_.Control -and $_.KeyCode -eq 'Enter'){$copy.PerformClick()}
    elseif($_.Alt -and $_.KeyCode -eq 'S'){$save.PerformClick()}
    elseif($_.Alt -and $_.KeyCode -eq 'D'){$remove.PerformClick()}
})
if($script:lastPreset -and $combo.Items.Contains($script:lastPreset)){$combo.SelectedItem=$script:lastPreset}else{$combo.SelectedIndex=0}
[void]$form.ShowDialog()
