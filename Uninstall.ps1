$shortcut = Join-Path ([Environment]::GetFolderPath('SendTo')) 'E F G に一括コピー.lnk'
if (Test-Path -LiteralPath $shortcut) { Remove-Item -LiteralPath $shortcut -Force }
$installDir = Join-Path $env:LOCALAPPDATA 'Programs\MultiDriveCopy'
if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
Write-Host 'アンインストールしました。プリセットは %APPDATA%\MultiDriveCopy に残しています。'
