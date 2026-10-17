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

Describe 'copy progress behavior' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'MultiDriveCopy.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('CopyFile', 'CopyDir', 'Update-CopyProgress')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        function Conflict($path) { return 'Skip' }
    }
    BeforeEach {
        $script:cancel = $false; $script:copied = 0; $script:skipped = 0
        $script:completedWork = 0; $script:totalWork = 6; $script:total = 2
        $script:progressBar = New-Object Windows.Forms.ProgressBar
        $script:progressBar.Maximum = 1000
        $script:statusLabel = New-Object Windows.Forms.Label
    }
    It 'updates progress immediately when a file is skipped' {
        $src = Join-Path $TestDrive 'skip-source.txt'; $dest = Join-Path $TestDrive 'skip-dest.txt'
        [IO.File]::WriteAllBytes($src, [byte[]](1,2)); [IO.File]::WriteAllText($dest, 'existing')
        CopyFile $src $dest
        $script:skipped | Should Be 1
        $script:progressBar.Value | Should Be 500
    }
    It 'accounts for every file when a conflicting folder is skipped' {
        $src = Join-Path $TestDrive 'skip-folder'; $dest = Join-Path $TestDrive 'folder-conflict'
        [IO.Directory]::CreateDirectory($src) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $src 'a'), [byte[]](1,2))
        [IO.File]::WriteAllBytes((Join-Path $src 'b'), [byte[]](3,4))
        [IO.File]::WriteAllText($dest, 'existing')
        CopyDir $src $dest
        $script:skipped | Should Be 2
        $script:progressBar.Value | Should Be 1000
    }
    It 'copies to multiple destinations and completes the combined progress' {
        $src = Join-Path $TestDrive 'multi-source'; $first = Join-Path $TestDrive 'first'; $second = Join-Path $TestDrive 'second'
        [IO.File]::WriteAllBytes($src, [byte[]](1,2))
        CopyFile $src $first
        $script:progressBar.Value | Should Be 500
        CopyFile $src $second
        $script:progressBar.Value | Should Be 1000
        $script:copied | Should Be 2
        [IO.File]::ReadAllBytes($first)[1] | Should Be 2
        [IO.File]::ReadAllBytes($second)[1] | Should Be 2
    }
    It 'reports bytes during a real file copy before completion' {
        $src = Join-Path $TestDrive 'large-source'; $dest = Join-Path $TestDrive 'large-dest'
        [IO.File]::WriteAllBytes($src, (New-Object byte[] (4MB)))
        $script:observed = New-Object System.Collections.ArrayList
        Copy-FileWithProgress $src $dest { param($bytes) [void]$script:observed.Add($bytes) }
        [IO.File]::ReadAllBytes($dest).Length | Should Be (4MB)
        @($script:observed | Where-Object { $_ -gt 0 -and $_ -lt 4MB }).Count | Should BeGreaterThan 0
    }
}
