$sendTo = [Environment]::GetFolderPath('SendTo')
$shortcut = Join-Path $sendTo 'E F G に一括コピー.lnk'
if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
Get-ChildItem -LiteralPath $sendTo -Filter 'E F G に一括コピー - *.lnk' -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\MultiDriveCopy'
if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
Write-Host 'アンインストールしました。プリセットは %APPDATA%\MultiDriveCopy に残しています。'
