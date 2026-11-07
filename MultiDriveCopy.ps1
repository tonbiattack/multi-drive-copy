param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Sources)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[Windows.Forms.Application]::EnableVisualStyles()
. (Join-Path $PSScriptRoot 'MultiDriveCopy.Core.ps1')
# Application state shared by the UI event handlers and copy functions.
$script:settings=Join-Path $env:APPDATA 'MultiDriveCopy\presets.json'
$script:presets=[ordered]@{}
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
    Save-PresetSettings $script:settings $script:presets $script:lastPreset
}
if(Test-Path -LiteralPath $script:settings) {
    try {
        $saved=Get-PresetSettings $script:settings
        foreach($p in @($saved.presets)){if($p.name -and $null -ne $p.path){$script:presets[[string]$p.name]=[string]$p.path}}
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
    if($script:presets.Contains($name)){$pathbox.Text=[string]$script:presets[$name];$script:lastPreset=$name;Persist}
})
$save.Add_Click({
    try{
        $p=Relative $pathbox.Text
        $name=[Microsoft.VisualBasic.Interaction]::InputBox('パターン名','コピー先を保存',[string]$combo.Text).Trim()
        if(!$name){return}
        $script:presets[$name]=$p
        Persist
        if(!$combo.Items.Contains($name)){[void]$combo.Items.Add($name)}
        $combo.SelectedItem=$name
    }catch{Alert $_.Exception.Message}
})
$remove.Add_Click({
    $name=[string]$combo.SelectedItem
    if(!$name){return}
    if([Windows.Forms.MessageBox]::Show("パターン '$name' を削除しますか？",'確認','YesNo','Question') -ne 'Yes'){return}
    $script:presets.Remove($name)
    Persist
    $combo.Items.Remove($name)
    if($combo.Items.Count){$combo.SelectedIndex=0}else{$pathbox.Clear()}
})
$copy.Add_Click({
    try{
        if(!$list.Items.Count){throw 'コピー元がありません。「送る」から起動してください。'}
        $relative=Relative $pathbox.Text
        $letters=@($drives|Where-Object {$_.Checked}|ForEach-Object {$_.Tag})
        if(!$letters.Count){throw 'コピー先ドライブを選んでください。'}
        $destinations=@()
        foreach($letter in $letters){
            $root=$letter+':\'
            if(!(Test-Path -LiteralPath $root)){throw 'ドライブが存在しません: '+$root}
            if($relative){$root=Join-Path $root $relative}
            $destinations+=,$root
            foreach($src in $list.Items){
                $full=[IO.Path]::GetFullPath([string]$src).TrimEnd('\')
                $target=[IO.Path]::GetFullPath((Join-Path $root ([IO.Path]::GetFileName($full)))).TrimEnd('\')
                if($full.Equals($target,[StringComparison]::OrdinalIgnoreCase) -or $target.StartsWith($full+'\',[StringComparison]::OrdinalIgnoreCase)){
                    throw 'コピー元自身・コピー元配下へのコピーはできません: '+$target
                }
            }
        }
        $missingDirectories=@(Get-MissingDestinationDirectories $destinations)
        $question='コピー元: '+$list.Items.Count+' 項目'+[Environment]::NewLine+'コピー先: '+($destinations -join ', ')+[Environment]::NewLine+'コピーしますか？'
        if($missingDirectories.Count){$question+=[Environment]::NewLine+'新規作成するフォルダ:'+[Environment]::NewLine+($missingDirectories -join [Environment]::NewLine)}
        if([Windows.Forms.MessageBox]::Show($question,'実行確認','YesNo','Question') -ne 'Yes'){return}
        foreach($directory in $missingDirectories){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
        $script:all=$null;$script:cancel=$false;$script:copied=0;$script:skipped=0
        $work=Get-CopyWork @($list.Items)
        $script:total=$work.Count*$destinations.Count;$script:totalWork=$work.Work*$destinations.Count;$script:completedWork=0
        $progress.Maximum=1000;$progress.Value=0
        $script:copying=$true
        foreach($control in @($list,$combo,$save,$remove,$pathbox,$copy)+$drives){$control.Enabled=$false}
        $form.Cursor='WaitCursor'
        Update-CopyProgress
        foreach($root in $destinations){
            foreach($src in $list.Items){
                if($script:cancel){break}
                $name=[IO.Path]::GetFileName(([string]$src).TrimEnd('\'))
                $target=Join-Path $root $name
                if([IO.Directory]::Exists([string]$src)){CopyDir ([string]$src) $target}
                else{CopyFile ([string]$src) $target}
            }
            if($script:cancel){break}
        }
        if(!$script:cancel -and $script:totalWork -eq 0){$progress.Value=$progress.Maximum}
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
