$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
$source = Join-Path $PSScriptRoot 'MultiDriveCopy.ps1'
if (!(Test-Path -LiteralPath $source)) { throw 'MultiDriveCopy.ps1 が見つかりません。' }
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\MultiDriveCopy'
New-Item -ItemType Directory -Path $installDir -Force | Out-Null
$target = Join-Path $installDir 'MultiDriveCopy.ps1'
Copy-Item -LiteralPath $source -Destination $target -Force
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
[System.Windows.Forms.MessageBox]::Show("インストールしました。複数選択 → 右クリック → 送る → E F G に一括コピー", 'Multi Drive Copy', 'OK', 'Information') | Out-Null
