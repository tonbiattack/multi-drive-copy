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

    It 'creates a recycle shortcut for presets that verify and recycle sources' {
        $sendTo = Join-Path $TestDrive 'SendToRecycle'
        New-Item -ItemType Directory -Path $sendTo | Out-Null
        $target = Join-Path $TestDrive 'MultiDriveCopy.ps1'
        Set-Content -LiteralPath $target -Value '# test'
        $presets = @(
            [pscustomobject]@{ name = 'Daily'; path = 'Backup\Daily' },
            [pscustomobject]@{ name = 'Archive'; path = 'Backup\Archive'; recycle = $true }
        )

        Sync-PresetSendToShortcuts -TargetScript $target -Presets $presets -SendToPath $sendTo

        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー - Daily.lnk')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー（検証してごみ箱へ） - Archive.lnk')) | Should Be $true
        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー - Archive.lnk')) | Should Be $false
        $shell = New-Object -ComObject WScript.Shell
        $link = $shell.CreateShortcut((Join-Path $sendTo 'E F G に一括コピー（検証してごみ箱へ） - Archive.lnk'))
        $link.Arguments | Should Match '-Preset "Archive"'
    }

    It 'removes a recycle shortcut when the preset no longer recycles' {
        $sendTo = Join-Path $TestDrive 'SendToRecycleOff'
        New-Item -ItemType Directory -Path $sendTo | Out-Null
        $target = Join-Path $TestDrive 'MultiDriveCopy.ps1'
        Set-Content -LiteralPath $target -Value '# test'
        $recyclePreset = @([pscustomobject]@{ name = 'Archive'; path = 'Backup\Archive'; recycle = $true })
        $plainPreset = @([pscustomobject]@{ name = 'Archive'; path = 'Backup\Archive' })

        Sync-PresetSendToShortcuts -TargetScript $target -Presets $recyclePreset -SendToPath $sendTo
        Sync-PresetSendToShortcuts -TargetScript $target -Presets $plainPreset -SendToPath $sendTo

        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー（検証してごみ箱へ） - Archive.lnk')) | Should Be $false
        (Test-Path -LiteralPath (Join-Path $sendTo 'E F G に一括コピー - Archive.lnk')) | Should Be $true
    }

    It 'round-trips the recycle flag through preset settings' {
        $settingsPath = Join-Path $TestDrive 'recycle-presets.json'
        Save-PresetSettings $settingsPath ([ordered]@{ Daily = 'Backup\Daily'; Archive = 'Backup\Archive' }) 'Daily' @{ Daily = @('E') } @{ Archive = $true }

        $settings = Get-PresetSettings $settingsPath

        $daily = @($settings.presets | Where-Object { $_.name -eq 'Daily' })[0]
        $archive = @($settings.presets | Where-Object { $_.name -eq 'Archive' })[0]
        $daily.recycle | Should BeNullOrEmpty
        $archive.recycle | Should Be $true
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

Describe 'source list manifests' {
    It 'reads UTF-8 JSON with Japanese paths, spaces, and duplicate entries' {
        $directory = Join-Path $TestDrive '連携 フォルダ'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $file = Join-Path $directory 'レポート 2026.txt'
        Set-Content -LiteralPath $file -Value 'manifest'
        $manifestPath = Join-Path $TestDrive 'ソース リスト.json'
        $json = @{ sources = @($file, $file.ToUpperInvariant(), ($directory + '\')) } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($manifestPath, $json, (New-Object Text.UTF8Encoding($false)))

        $result = @(Read-SourceListFile $manifestPath)

        $result.Count | Should Be 2
        $result[0] | Should Be $file
        $result[1].TrimEnd('\') | Should Be $directory.TrimEnd('\')
    }

    It 'reads a UTF-8 BOM manifest and a single-item array' {
        $file = Join-Path $TestDrive 'bom-source.txt'
        Set-Content -LiteralPath $file -Value 'bom'
        $manifestPath = Join-Path $TestDrive 'bom-sources.json'
        $json = @{ sources = @($file) } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($manifestPath, $json, (New-Object Text.UTF8Encoding($true)))

        $result = @(Read-SourceListFile $manifestPath)

        $result.Count | Should Be 1
        $result[0] | Should Be $file
    }

    It 'reads a large manifest without losing entries' {
        $directory = Join-Path $TestDrive 'bulk'
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $files = @()
        for ($i = 1; $i -le 100; $i++) {
            $file = Join-Path $directory ('file-{0:D3}.txt' -f $i)
            [IO.File]::WriteAllText($file, [string]$i)
            $files += $file
        }
        $manifestPath = Join-Path $TestDrive 'bulk-sources.json'
        $json = @{ sources = $files } | ConvertTo-Json -Depth 5
        [IO.File]::WriteAllText($manifestPath, $json, (New-Object Text.UTF8Encoding($false)))

        $result = @(Read-SourceListFile $manifestPath)

        $result.Count | Should Be 100
        $result[0] | Should Be $files[0]
        $result[99] | Should Be $files[99]
    }

    It 'rejects malformed and unsafe manifests' {
        $invalidJson = Join-Path $TestDrive 'invalid.json'
        Set-Content -LiteralPath $invalidJson -Value '{'
        { Read-SourceListFile $invalidJson } | Should Throw

        $missingSources = Join-Path $TestDrive 'missing-sources.json'
        Set-Content -LiteralPath $missingSources -Value '{"items":[]}'
        { Read-SourceListFile $missingSources } | Should Throw

        $notArray = Join-Path $TestDrive 'not-array.json'
        Set-Content -LiteralPath $notArray -Value '{"sources":"C:\\file.txt"}'
        { Read-SourceListFile $notArray } | Should Throw

        $notString = Join-Path $TestDrive 'not-string.json'
        Set-Content -LiteralPath $notString -Value '{"sources":[123]}'
        { Read-SourceListFile $notString } | Should Throw

        $relative = Join-Path $TestDrive 'relative.json'
        Set-Content -LiteralPath $relative -Value '{"sources":["folder\\file.txt"]}'
        { Read-SourceListFile $relative } | Should Throw

        $empty = Join-Path $TestDrive 'empty.json'
        Set-Content -LiteralPath $empty -Value '{"sources":[]}'
        { Read-SourceListFile $empty } | Should Throw

        $missingPath = Join-Path $TestDrive 'missing-path.json'
        $missingValue = 'C:\\mdc-missing-' + [guid]::NewGuid().ToString('N') + '.txt'
        Set-Content -LiteralPath $missingPath -Value ('{"sources":["' + $missingValue.Replace('\', '\\') + '"]}')
        { Read-SourceListFile $missingPath } | Should Throw

        $quotedPath = Join-Path $TestDrive 'quoted.json'
        Set-Content -LiteralPath $quotedPath -Value '{"sources":["C:\\bad\"quote.txt"]}'
        { Read-SourceListFile $quotedPath } | Should Throw

        { Read-SourceListFile (Join-Path $TestDrive 'does-not-exist.json') } | Should Throw
    }

    It 'merges command-line and manifest sources without duplicates' {
        $commandLine = Join-Path $TestDrive 'command-line.txt'
        $manifest = Join-Path $TestDrive 'manifest.txt'
        $missing = Join-Path $TestDrive 'missing.txt'
        Set-Content -LiteralPath $commandLine -Value 'command'
        Set-Content -LiteralPath $manifest -Value 'manifest'

        $result = Merge-SourcePaths -CommandLineSources @($commandLine, $missing) -ManifestSources @($commandLine.ToUpperInvariant(), $manifest)

        $result.Sources.Count | Should Be 2
        $result.Duplicates | Should Be 1
        $result.Sources[0] | Should Be $commandLine
        $result.Sources[1] | Should Be $manifest
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
        foreach ($name in @('Add-CopyMapping', 'Add-CopyDirMapping', 'Unique', 'CopyFile', 'CopyDir', 'Update-CopyProgress', 'Start-CopyOperation', 'Complete-CopyAndClose')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        function Conflict($path) { if ($script:conflictChoice) { return [string]$script:conflictChoice }; return 'Skip' }
    }
    BeforeEach {
        $script:cancel = $false; $script:copied = 0; $script:skipped = 0
        $script:completedWork = 0; $script:totalWork = 6; $script:total = 2
        $script:copyMap = $null
        $script:copyDirMap = $null
        $script:conflictChoice = $null
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

Describe 'folder verification behavior' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'MultiDriveCopy.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Add-CopyMapping', 'Add-CopyDirMapping', 'Unique', 'CopyFile', 'CopyDir', 'Update-CopyProgress', 'Start-CopyOperation', 'Complete-CopyAndClose')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        function Conflict($path) { if ($script:conflictChoice) { return [string]$script:conflictChoice }; return 'Skip' }
        function New-FolderFixture([string]$Name, [string]$Content = 'verified') {
            $root = Join-Path $TestDrive $Name
            $source = Join-Path $root 'source'
            $destinations = @((Join-Path $root 'dest1'), (Join-Path $root 'dest2'))
            New-Item -ItemType Directory -Path (Join-Path $source 'empty'), (Join-Path $source 'nested') -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $source 'nested\file.txt') -Value $Content
            return @{ Root = $root; Source = $source; Destinations = $destinations }
        }
        function Get-FolderResultsForFixture($Fixture) {
            $fileResults = @(Get-CopyVerification -SourceFiles @($script:sourceFiles) -CopyMap @($script:copyMap) -DestinationCount @($Fixture.Destinations).Count)
            $folderResults = @(Get-FolderVerification -SourceFolders @($Fixture.Source) -FileResults $fileResults -DirectoryMap @($script:copyDirMap) -DestinationCount @($Fixture.Destinations).Count)
            return @{ FileResults = $fileResults; FolderResults = $folderResults }
        }
    }
    BeforeEach {
        $script:cancel = $false; $script:copied = 0; $script:skipped = 0
        $script:completedWork = 0; $script:totalWork = 6; $script:total = 2
        $script:copyMap = $null
        $script:copyDirMap = $null
        $script:conflictChoice = $null
        $script:sourceFiles = @()
        $script:progressBar = New-Object Windows.Forms.ProgressBar
        $script:progressBar.Maximum = 1000
        $script:statusLabel = New-Object Windows.Forms.Label
    }

    It 'records directory mappings including empty folders' {
        $root = Join-Path $TestDrive 'mapping-source'
        $source = Join-Path $root 'source'
        $destination = Join-Path $root 'destination'
        New-Item -ItemType Directory -Path (Join-Path $source 'empty'), (Join-Path $source 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'nested\file.txt') -Value 'data'

        CopyDir $source $destination

        @($script:copyDirMap).Count | Should Be 3
        $emptyRow = @($script:copyDirMap | Where-Object { $_.Source -eq (Join-Path $source 'empty') })
        $emptyRow.Count | Should Be 1
        $emptyRow[0].Destination | Should Be (Join-Path $destination 'empty')
    }

    It 'verifies a folder when files and empty folders exist at every destination' {
        $fixture = New-FolderFixture 'verified-folder'
        Start-CopyOperation @($fixture.Source) $fixture.Destinations
        $results = Get-FolderResultsForFixture $fixture

        $results.FolderResults[0].Status | Should Be 'Verified'
        $results.FolderResults[0].FileCount | Should Be 1
        $results.FolderResults[0].DirectoryCount | Should Be 3
        @($results.FolderResults[0].Destinations).Count | Should Be 2
        (Test-FolderResultStillValid $results.FolderResults[0]) | Should Be $true
    }

    It 'verifies an empty folder against every destination' {
        $root = Join-Path $TestDrive 'empty-folder'
        $source = Join-Path $root 'source'
        $destinations = @((Join-Path $root 'dest1'), (Join-Path $root 'dest2'))
        New-Item -ItemType Directory -Path $source -Force | Out-Null
        Start-CopyOperation @($source) $destinations
        $fixture = @{ Source = $source; Destinations = $destinations }
        $results = Get-FolderResultsForFixture $fixture

        $results.FolderResults[0].Status | Should Be 'Verified'
        $results.FolderResults[0].FileCount | Should Be 0
        $results.FolderResults[0].DirectoryCount | Should Be 1
    }

    It 'protects a folder when an empty directory is missing at a destination' {
        $fixture = New-FolderFixture 'missing-empty-dir'
        Start-CopyOperation @($fixture.Source) $fixture.Destinations
        Remove-Item -LiteralPath (Join-Path (Join-Path $fixture.Destinations[1] 'source') 'empty') -Force
        $results = Get-FolderResultsForFixture $fixture

        $results.FolderResults[0].Status | Should Be 'Protected'
        $results.FolderResults[0].Reason | Should Match 'コピー先ディレクトリ'
    }

    It 'protects a folder when a destination file differs' {
        $fixture = New-FolderFixture 'mismatch-folder'
        Start-CopyOperation @($fixture.Source) $fixture.Destinations
        Set-Content -LiteralPath (Join-Path (Join-Path $fixture.Destinations[0] 'source') 'nested\file.txt') -Value 'tampered'
        $results = Get-FolderResultsForFixture $fixture

        $results.FolderResults[0].Status | Should Be 'Protected'
        $results.FolderResults[0].Reason | Should Match 'ファイル検証に失敗'
    }

    It 'protects a folder when a file was added to the source after copy' {
        $fixture = New-FolderFixture 'added-source-file'
        Start-CopyOperation @($fixture.Source) $fixture.Destinations
        Set-Content -LiteralPath (Join-Path $fixture.Source 'added.txt') -Value 'new'
        $results = Get-FolderResultsForFixture $fixture

        $results.FolderResults[0].Status | Should Be 'Protected'
        $results.FolderResults[0].Reason | Should Match '検証結果のないファイル'
    }

    It 'protects a folder when a source file was deleted after copy' {
        $fixture = New-FolderFixture 'deleted-source-file'
        Start-CopyOperation @($fixture.Source) $fixture.Destinations
        Remove-Item -LiteralPath (Join-Path $fixture.Source 'nested\file.txt') -Force
        $results = Get-FolderResultsForFixture $fixture

        $results.FolderResults[0].Status | Should Be 'Protected'
        $results.FolderResults[0].Reason | Should Match '削除・変更されたファイル'
    }

    It 'follows a renamed destination folder during verification' {
        $root = Join-Path $TestDrive 'renamed-folder'
        $source = Join-Path $root 'source'
        $destinationRoot = Join-Path $root 'destination'
        New-Item -ItemType Directory -Path $source, $destinationRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'renamed'
        Set-Content -LiteralPath (Join-Path $destinationRoot 'source') -Value 'conflict'
        $script:conflictChoice = 'Rename'

        Start-CopyOperation @($source) @($destinationRoot)
        $fileResults = @(Get-CopyVerification -SourceFiles @($script:sourceFiles) -CopyMap @($script:copyMap) -DestinationCount 1)
        $folderResults = @(Get-FolderVerification -SourceFolders @($source) -FileResults $fileResults -DirectoryMap @($script:copyDirMap) -DestinationCount 1)

        $folderResults[0].Status | Should Be 'Verified'
        $folderResults[0].Destinations[0] | Should Match 'source \(1\)$'
        (Test-FolderResultStillValid $folderResults[0]) | Should Be $true
    }

    It 'accepts a skipped file only when its existing destination matches' {
        $root = Join-Path $TestDrive 'skipped-folder'
        $source = Join-Path $root 'source'
        $destinationRoot = Join-Path $root 'destination'
        New-Item -ItemType Directory -Path (Join-Path $source 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'nested\file.txt') -Value 'same'
        New-Item -ItemType Directory -Path (Join-Path $destinationRoot 'source\nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $destinationRoot 'source\nested\file.txt') -Value 'same'
        $script:conflictChoice = 'Skip'

        Start-CopyOperation @($source) @($destinationRoot)
        $fileResults = @(Get-CopyVerification -SourceFiles @($script:sourceFiles) -CopyMap @($script:copyMap) -DestinationCount 1)
        $folderResults = @(Get-FolderVerification -SourceFolders @($source) -FileResults $fileResults -DirectoryMap @($script:copyDirMap) -DestinationCount 1)

        $folderResults[0].Status | Should Be 'Verified'
        $fileResults[0].Action | Should Be 'Skipped'
    }

    It 'protects a folder when a skipped file differs at the destination' {
        $root = Join-Path $TestDrive 'skipped-different-folder'
        $source = Join-Path $root 'source'
        $destinationRoot = Join-Path $root 'destination'
        New-Item -ItemType Directory -Path (Join-Path $source 'nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'nested\file.txt') -Value 'same'
        New-Item -ItemType Directory -Path (Join-Path $destinationRoot 'source\nested') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $destinationRoot 'source\nested\file.txt') -Value 'different'
        $script:conflictChoice = 'Skip'

        Start-CopyOperation @($source) @($destinationRoot)
        $fileResults = @(Get-CopyVerification -SourceFiles @($script:sourceFiles) -CopyMap @($script:copyMap) -DestinationCount 1)
        $folderResults = @(Get-FolderVerification -SourceFolders @($source) -FileResults $fileResults -DirectoryMap @($script:copyDirMap) -DestinationCount 1)

        $folderResults[0].Status | Should Be 'Protected'
        $folderResults[0].Reason | Should Match 'ファイル検証に失敗'
    }

    It 'does not record folder mappings after cancellation' {
        $root = Join-Path $TestDrive 'cancelled-folder'
        $source = Join-Path $root 'source'
        $destinationRoot = Join-Path $root 'destination'
        New-Item -ItemType Directory -Path $source, $destinationRoot -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $source 'file.txt') -Value 'cancel'
        Set-Content -LiteralPath (Join-Path $destinationRoot 'source') -Value 'conflict'
        $script:conflictChoice = 'Cancel'

        Start-CopyOperation @($source) @($destinationRoot)

        $script:cancel | Should Be $true
        @($script:copyDirMap | Where-Object { $_.Source -eq $source }).Count | Should Be 0
    }

    It 'detects nested and overlapping source selections' {
        $parent = Join-Path $TestDrive 'overlap-parent'
        $child = Join-Path $parent 'child'
        $sibling = Join-Path $TestDrive 'overlap-sibling'
        New-Item -ItemType Directory -Path $child, $sibling -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'file.txt') -Value 'overlap'

        (Test-SourceOverlap @($parent, $child)) | Should Be $true
        (Test-SourceOverlap @($parent, (Join-Path $child 'file.txt'))) | Should Be $true
        (Test-SourceOverlap @($parent, $sibling)) | Should Be $false
    }

    It 'detects parent and child relationships between sources and destinations' {
        $sourceParent = Join-Path $TestDrive 'relation-source'
        $destinationInside = Join-Path $sourceParent 'inside'
        $destinationRoot = Join-Path $TestDrive 'relation-destination'
        $sourceInside = Join-Path $destinationRoot 'child'
        $sibling = Join-Path $TestDrive 'relation-sibling'
        New-Item -ItemType Directory -Path $destinationInside, $destinationRoot, $sourceInside, $sibling -Force | Out-Null

        (Test-SourceUnderDestination -Sources @($sourceParent) -Destinations @($destinationInside)) | Should Be $true
        (Test-SourceUnderDestination -Sources @($sourceInside) -Destinations @($destinationRoot)) | Should Be $true
        (Test-SourceUnderDestination -Sources @($sibling) -Destinations @($destinationRoot)) | Should Be $false
    }

    It 'marks a tree with a junction as unsafe' {
        $source = Join-Path $TestDrive 'junction-source'
        $target = Join-Path $TestDrive 'junction-target'
        New-Item -ItemType Directory -Path $source, $target -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $target 'file.txt') -Value 'target'
        $link = Join-Path $source 'link'
        New-Item -ItemType Junction -Path $link -Target $target | Out-Null
        try {
            $tree = Get-SourceTree $source
            $tree.Unsafe | Should Be $true

            $folderResults = @(Get-FolderVerification -SourceFolders @($source) -FileResults @() -DirectoryMap @() -DestinationCount 1)
            $folderResults[0].Status | Should Be 'Protected'
            $folderResults[0].Reason | Should Match 'ジャンクション'
        } finally {
            [IO.Directory]::Delete($link)
        }
    }

    It 'rejects a verified folder after its source or destination changes' {
        $fixture = New-FolderFixture 'changed-folder'
        Start-CopyOperation @($fixture.Source) $fixture.Destinations
        $results = Get-FolderResultsForFixture $fixture
        (Test-FolderResultStillValid $results.FolderResults[0]) | Should Be $true

        Set-Content -LiteralPath (Join-Path (Join-Path $fixture.Destinations[0] 'source') 'nested\file.txt') -Value 'changed'
        (Test-FolderResultStillValid $results.FolderResults[0]) | Should Be $false

        $fixture2 = New-FolderFixture 'changed-folder-source'
        Start-CopyOperation @($fixture2.Source) $fixture2.Destinations
        $results2 = Get-FolderResultsForFixture $fixture2
        (Test-FolderResultStillValid $results2.FolderResults[0]) | Should Be $true
        Set-Content -LiteralPath (Join-Path $fixture2.Source 'added.txt') -Value 'new'
        (Test-FolderResultStillValid $results2.FolderResults[0]) | Should Be $false
    }
}

Describe 'one-click verify and recycle flow' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $projectRoot 'MultiDriveCopy.ps1'), [ref]$null, [ref]$null)
        foreach ($name in @('Add-CopyMapping', 'Add-CopyDirMapping', 'Unique', 'CopyFile', 'CopyDir', 'Update-CopyProgress', 'Start-CopyOperation', 'Complete-CopyAndClose', 'Get-CopyVerificationResults')) {
            $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }.GetNewClosure(), $true)
            if ($definition) { . ([scriptblock]::Create($definition.Extent.Text)) }
        }
        function Conflict($path) { if ($script:conflictChoice) { return [string]$script:conflictChoice }; return 'Skip' }
    }
    BeforeEach {
        $script:cancel = $false; $script:copied = 0; $script:skipped = 0
        $script:completedWork = 0; $script:totalWork = 6; $script:total = 2
        $script:copyMap = $null
        $script:copyDirMap = $null
        $script:conflictChoice = $null
        $script:sourceFiles = @()
        $script:progressBar = $null
        $script:statusLabel = $null
    }

    It 'returns verified top-level results for files and folders in one call' {
        $root = Join-Path $TestDrive 'one-click'
        $file = Join-Path $root 'report.txt'
        $folder = Join-Path $root 'photos'
        $destinations = @((Join-Path $root 'dest1'), (Join-Path $root 'dest2'))
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        Set-Content -LiteralPath $file -Value 'report'
        Set-Content -LiteralPath (Join-Path $folder 'a.jpg') -Value 'photo'

        Start-CopyOperation @($file, $folder) $destinations
        $verification = Get-CopyVerificationResults -Sources @($file, $folder) -Destinations $destinations

        @($verification.Results).Count | Should Be 2
        @($verification.Results | Where-Object { $_.Status -eq 'Verified' }).Count | Should Be 2
        $verification.LogPath | Should Match 'verify-'
        @($verification.FileResults).Count | Should Be 2
    }

    It 'reports the verification progress through the status callback' {
        $root = Join-Path $TestDrive 'one-click-progress'
        $file = Join-Path $root 'progress.txt'
        $destination = Join-Path $root 'dest'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Set-Content -LiteralPath $file -Value 'progress'
        $script:observed = New-Object System.Collections.ArrayList

        Start-CopyOperation @($file) @($destination)
        $verification = Get-CopyVerificationResults -Sources @($file) -Destinations @($destination) -OnStatus {
            param($text, $i, $total)
            [void]$script:observed.Add($text)
        }

        @($script:observed).Count | Should BeGreaterThan 0
        @($script:observed | Where-Object { $_ -match '検証' }).Count | Should BeGreaterThan 0
        @($verification.Results)[0].Status | Should Be 'Verified'
    }

    It 'protects nested sources instead of recycling them' {
        $root = Join-Path $TestDrive 'one-click-overlap'
        $parent = Join-Path $root 'parent'
        $child = Join-Path $parent 'child'
        $destination = Join-Path $root 'dest'
        New-Item -ItemType Directory -Path $child -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $child 'file.txt') -Value 'overlap'

        Start-CopyOperation @($parent) @($destination)
        $verification = Get-CopyVerificationResults -Sources @($parent, $child) -Destinations @($destination)

        @($verification.Results | Where-Object { $_.Status -eq 'Protected' }).Count | Should Be 2
    }
}