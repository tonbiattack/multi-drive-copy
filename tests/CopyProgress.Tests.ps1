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

    It 'preserves per-preset drives without breaking older settings' {
        $settingsPath = Join-Path $TestDrive 'presets.json'
        Save-PresetSettings $settingsPath ([ordered]@{ Daily = 'Backup\Daily' }) 'Daily' @{ Daily = @('E', 'G') }

        $settings = Get-PresetSettings $settingsPath
        (@($settings.presets[0].drives) -join ',') | Should Be 'E,G'
        $settings.presets[0].drives | Should Not BeNullOrEmpty

        Save-PresetSettings $settingsPath ([ordered]@{ Legacy = 'Backup\Legacy' }) 'Legacy'
        $legacy = Get-PresetSettings $settingsPath
        $legacy.presets[0].drives | Should BeNullOrEmpty
    }

    It 'removes invalid characters from preset shortcut file names' {
        (ConvertTo-ShortcutFileName 'A/B:C*D?E"F<G>H|I') | Should Be 'A_B_C_D_E_F_G_H_I'
        (ConvertTo-ShortcutFileName '   ') | Should Be 'preset'
    }

    It 'resolves one destination per drive and rejects a source copied onto itself' {
        $source = Join-Path $TestDrive 'resolved.txt'
        Set-Content -LiteralPath $source -Value 'resolved'
        $testRoot = $TestDrive.FullName
        $letter = $testRoot.Substring(0, 1)
        $relative = $testRoot.Substring(3)

        $destinations = @(Resolve-CopyDestinations -Sources @($source) -RelativePath 'Temp' -DriveLetters @($letter))
        $destinations.Count | Should Be 1
        $destinations[0] | Should Be ($letter + ':\Temp')

        { Resolve-CopyDestinations -Sources @($source) -RelativePath $relative -DriveLetters @($letter) } | Should Throw
    }

    It 'creates direct preset shortcuts and removes stale ones' {
        $sendTo = Join-Path $TestDrive 'SendTo'
        New-Item -ItemType Directory -Path $sendTo | Out-Null
        $target = Join-Path $TestDrive 'MultiDriveCopy.ps1'
        Set-Content -LiteralPath $target -Value '# test'
        $stale = Join-Path $sendTo 'E F G に一括コピー - Stale.lnk'
        [IO.File]::WriteAllText($stale, 'stale')
        $presets = @(
            [pscustomobject]@{ name = 'Daily'; path = 'Backup\Daily' },
            [pscustomobject]@{ name = 'A/B'; path = 'Backup\AB' },
            [pscustomobject]@{ name = 'A:B'; path = 'Backup\AB2' }
        )

        Sync-PresetSendToShortcuts -TargetScript $target -Presets $presets -SendToPath $sendTo

        (Test-Path -LiteralPath $stale) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー - Daily.lnk')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー - A_B.lnk')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー - A_B (2).lnk')) | Should Be $true
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path $sendTo 'E F G に一括コピー - Daily.lnk'))
        $link.Arguments | Should Match '-Preset "Daily"'
        $link.TargetPath | Should Match 'powershell\.exe$'
    }

    It 'returns the enumerated files for verification' {
        $root = Join-Path $TestDrive 'work-source'
        New-Item -ItemType Directory -Path (Join-Path $root 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'top.txt') -Value 'top'
        Set-Content -LiteralPath (Join-Path $root 'nested\child.txt') -Value 'child'

        $work = Get-CopyWork @($root)

        @($work.Files).Count | Should Be 2
    }

    It 'returns each missing destination directory once' {
        $existing = Join-Path $TestDrive 'existing'
        $missing = Join-Path $TestDrive 'new\nested'
        New-Item -ItemType Directory -Path $existing | Out-Null

        $result = @(Get-MissingDestinationDirectories @($existing, $missing, $missing))

        $result.Count | Should Be 1
        $result[0] | Should Be $missing
    }
}

Describe 'copy verification' {
    It 'verifies a source only when every destination matches by size and SHA-256' {
        $source = Join-Path $TestDrive 'verify-source.txt'
        $first = Join-Path $TestDrive 'verify-first.txt'
        $second = Join-Path $TestDrive 'verify-second.txt'
        [IO.File]::WriteAllText($source, 'verified content')
        Copy-Item -LiteralPath $source -Destination $first
        Copy-Item -LiteralPath $source -Destination $second
        $map = @(
            [pscustomobject]@{ Source = $source; Destination = $first; Action = 'Copied' },
            [pscustomobject]@{ Source = $source; Destination = $second; Action = 'Overwritten' }
        )

        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 2)
        $summary = Get-VerificationSummary $results

        $results.Count | Should Be 1
        $results[0].Status | Should Be 'Verified'
        @($results[0].Destinations).Count | Should Be 2
        $summary.Verified | Should Be 1
        $summary.CandidateSize | Should Be ([IO.FileInfo]$source).Length
    }

    It 'marks a hash mismatch as not movable even when sizes are equal' {
        $source = Join-Path $TestDrive 'mismatch-source.txt'
        $first = Join-Path $TestDrive 'mismatch-first.txt'
        $second = Join-Path $TestDrive 'mismatch-second.txt'
        [IO.File]::WriteAllText($source, 'abc')
        Copy-Item -LiteralPath $source -Destination $first
        [IO.File]::WriteAllText($second, 'abd')
        $map = @(
            [pscustomobject]@{ Source = $source; Destination = $first; Action = 'Copied' },
            [pscustomobject]@{ Source = $source; Destination = $second; Action = 'Copied' }
        )

        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 2)

        $results[0].Status | Should Be 'Mismatch'
        $results[0].Reason | Should Match 'SHA-256'
    }

    It 'protects a source when a destination mapping is missing' {
        $source = Join-Path $TestDrive 'missing-dest-source.txt'
        $first = Join-Path $TestDrive 'missing-dest-first.txt'
        [IO.File]::WriteAllText($source, 'content')
        Copy-Item -LiteralPath $source -Destination $first
        $map = @([pscustomobject]@{ Source = $source; Destination = $first; Action = 'Copied' })

        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 2)

        $results[0].Status | Should Be 'Protected'
        $results[0].Reason | Should Match '不足'
    }

    It 'accepts a skipped destination when the existing file already matches' {
        $source = Join-Path $TestDrive 'skip-verify-source.txt'
        $destination = Join-Path $TestDrive 'skip-verify-destination.txt'
        [IO.File]::WriteAllText($source, 'same content')
        Copy-Item -LiteralPath $source -Destination $destination
        $map = @([pscustomobject]@{ Source = $source; Destination = $destination; Action = 'Skipped' })

        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 1)

        $results[0].Status | Should Be 'Verified'
        $results[0].Action | Should Be 'Skipped'
    }

    It 'rejects a source or destination that changed after verification' {
        $source = Join-Path $TestDrive 'changed-source.txt'
        $destination = Join-Path $TestDrive 'changed-destination.txt'
        [IO.File]::WriteAllText($source, 'original')
        Copy-Item -LiteralPath $source -Destination $destination
        $map = @([pscustomobject]@{ Source = $source; Destination = $destination; Action = 'Copied' })
        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 1)
        $results[0].Status | Should Be 'Verified'

        [IO.File]::WriteAllText($source, 'changed!')
        (Test-VerifiedResultStillValid $results[0]) | Should Be $false

        [IO.File]::WriteAllText($source, 'original')
        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 1)
        [IO.File]::WriteAllText($destination, 'tampered')
        (Test-VerifiedResultStillValid $results[0]) | Should Be $false
    }

    It 'writes a log with hash results and retry guidance' {
        $source = Join-Path $TestDrive 'log-source.txt'
        $destination = Join-Path $TestDrive 'log-destination.txt'
        $logPath = Join-Path $TestDrive 'logs\verify.log'
        [IO.File]::WriteAllText($source, 'log content')
        Copy-Item -LiteralPath $source -Destination $destination
        $map = @([pscustomobject]@{ Source = $source; Destination = $destination; Action = 'Copied' })
        $results = @(Get-CopyVerification -SourceFiles @($source) -CopyMap $map -DestinationCount 1)

        Write-VerificationLog -Path $logPath -Results $results -Summary (Get-VerificationSummary $results)
        $log = Get-Content -LiteralPath $logPath -Raw

        $log | Should Match 'SHA-256'
        $log | Should Match 'Verified'
        $log | Should Match 'リトライ'
    }
}

Describe 'copy progress behavior' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'MultiDriveCopy.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Add-CopyMapping', 'CopyFile', 'CopyDir', 'Update-CopyProgress', 'Start-CopyOperation', 'Complete-CopyAndClose')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        function Conflict($path) { return 'Skip' }
    }
    BeforeEach {
        $script:cancel = $false; $script:copied = 0; $script:skipped = 0
        $script:completedWork = 0; $script:totalWork = 6; $script:total = 2
        $script:copyMap = $null
        $script:sourceFiles = @()
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
        @($script:copyMap).Count | Should Be 1
        $script:copyMap[0].Action | Should Be 'Skipped'
        $script:copyMap[0].Destination | Should Be $dest
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
    It 'copies a source to every destination through the shared operation' {
        $src = Join-Path $TestDrive 'shared-source.txt'; $first = Join-Path $TestDrive 'shared-first'; $second = Join-Path $TestDrive 'shared-second'
        [IO.File]::WriteAllText($src, 'shared')

        Start-CopyOperation @($src) @($first, $second)

        $script:copied | Should Be 2
        [IO.File]::ReadAllText((Join-Path $first 'shared-source.txt')) | Should Be 'shared'
        [IO.File]::ReadAllText((Join-Path $second 'shared-source.txt')) | Should Be 'shared'
        @($script:sourceFiles).Count | Should Be 1
        @($script:copyMap).Count | Should Be 2
        $script:copyMap[0].Source | Should Be $src
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
    It 'closes the copy form after a completed result is dismissed' {
        $form = New-Object Windows.Forms.Form
        $form.Add_FormClosing({ if ($script:copying) { $_.Cancel = $true } })
        [void]$form.Handle
        $script:copying = $true

        Complete-CopyAndClose $form

        $script:copying | Should Be $false
        $form.IsDisposed | Should Be $true
    }
}
