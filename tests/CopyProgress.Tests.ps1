$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'MultiDriveCopy.Core.ps1')

Describe 'copy progress helpers' {
    It 'counts files recursively and excludes directories' {
        $root = Join-Path $TestDrive 'source'
        New-Item -ItemType Directory -Path (Join-Path $root 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'top.txt') -Value 'top'
        Set-Content -LiteralPath (Join-Path $root 'nested\child.txt') -Value 'child'

        (Get-CopyFileCount @($root)) | Should Be 2
    }

    It 'counts a selected file as one copy operation' {
        $file = Join-Path $TestDrive 'selected.txt'
        Set-Content -LiteralPath $file -Value 'selected'

        (Get-CopyFileCount @($file)) | Should Be 1
    }

    It 'preserves the last selected preset name when saving settings' {
        $settingsPath = Join-Path $TestDrive 'presets.json'
        Save-PresetSettings $settingsPath ([ordered]@{ Daily = 'Backup\Daily' }) 'Daily'

        $settings = Get-PresetSettings $settingsPath
        $settings.lastSelectedPreset | Should Be 'Daily'
        $settings.presets[0].name | Should Be 'Daily'
    }
}
