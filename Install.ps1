$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$source = Join-Path $PSScriptRoot 'MultiDriveCopy.ps1'
if (!(Test-Path -LiteralPath $source)) { throw 'MultiDriveCopy.ps1 が見つかりません。' }
$coreSource = Join-Path $PSScriptRoot 'MultiDriveCopy.Core.ps1'
if (!(Test-Path -LiteralPath $coreSource)) { throw 'MultiDriveCopy.Core.ps1 が見つかりません。' }
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\MultiDriveCopy'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$target = Join-Path $installDir 'MultiDriveCopy.ps1'
Copy-Item -LiteralPath $source -Destination $target -Force
Copy-Item -LiteralPath $coreSource -Destination (Join-Path $installDir 'MultiDriveCopy.Core.ps1') -Force
. (Join-Path $PSScriptRoot 'MultiDriveCopy.Core.ps1')
$sendTo = [Environment]::GetFolderPath('SendTo')
$shortcut = Join-Path $sendTo 'E F G に一括コピー.lnk'
$shell = New-Object -ComObject WScript.Shell
$link = $shell.CreateShortcut($shortcut)
$link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$link.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $target + '"'
$link.WorkingDirectory = $installDir
$link.IconLocation = "$env:SystemRoot\System32\shell32.dll,3"
$link.Description = '選択したファイル・フォルダを E F G の同一相対パスへコピー'
$link.Save()
$settingsPath = Join-Path $env:APPDATA 'MultiDriveCopy\presets.json'
$presets = @()
if (Test-Path -LiteralPath $settingsPath) {
    try {
        $saved = Get-PresetSettings $settingsPath
        $presets = @($saved.presets)
    } catch { $presets = @() }
}
Sync-PresetSendToShortcuts -TargetScript $target -Presets $presets
[System.Windows.Forms.MessageBox]::Show("インストールしました。複数選択 → 右クリック → 送る から、設定してコピーするか保存済みパターンを直接実行できます。", 'Multi Drive Copy', 'OK', 'Information') | Out-Null
