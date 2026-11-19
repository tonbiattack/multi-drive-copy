$projectRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $projectRoot 'MultiDriveCopy.Core.ps1')

Describe 'ZIP duplicate detection' {
    BeforeEach {
        $script:root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:source = Join-Path $script:root 'source'
        $script:dest1 = Join-Path $script:root 'dest1'
        $script:dest2 = Join-Path $script:root 'dest2'
        New-Item -ItemType Directory -Path $script:source, $script:dest1, $script:dest2 -Force | Out-Null
    }

    It 'recognises ZIP names case-insensitively and ignores other extensions' {
        (Test-ZipFileName 'a.zip') | Should Be $true
        (Test-ZipFileName 'a.ZIP') | Should Be $true
        (Test-ZipFileName 'a.Zip') | Should Be $true
        (Test-ZipFileName 'a.7z') | Should Be $false
        (Test-ZipFileName 'a.txt') | Should Be $false
        (Test-ZipFileName '') | Should Be $false
    }

    It 'reports no duplicate when the destination is empty' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'archive')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1, $script:dest2)

        @($check.Reports).Count | Should Be 1
        @($check.Reports[0].Matches).Count | Should Be 0
        (Format-ZipDuplicateSummary $check.Reports[0]) | Should Be '同名ZIP: なし'
    }

    It 'detects a same-named ZIP with a different size' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'new archive content')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'photos.zip'), 'old')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1, $script:dest2)

        @($check.Reports[0].Matches).Count | Should Be 1
        $check.Reports[0].Matches[0].State | Should Be 'DifferentSize'
        $check.Reports[0].Matches[0].Directory | Should Be $script:dest1
        (Format-ZipDuplicateSummary $check.Reports[0]) | Should Match '同名・サイズ違い 1 件'
    }

    It 'distinguishes a same-named ZIP with the same size without claiming equality' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'aaaa')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'photos.zip'), 'bbbb')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1)

        $check.Reports[0].Matches[0].State | Should Be 'SameSize'
        (Format-ZipDuplicateSummary $check.Reports[0]) | Should Match '同名・同サイズ 1 件'
    }

    It 'matches the destination name regardless of case' {
        $zip = Join-Path $script:source 'Photos.ZIP'
        [IO.File]::WriteAllText($zip, 'archive')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'photos.zip'), 'archive')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1)

        @($check.Reports[0].Matches).Count | Should Be 1
    }

    It 'reports duplicates across several destinations at once' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'archive')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'photos.zip'), 'one')
        [IO.File]::WriteAllText((Join-Path $script:dest2 'photos.zip'), 'two')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1, $script:dest2)

        @($check.Reports[0].Matches).Count | Should Be 2
        (Get-ZipDuplicateCounts @($check.Reports)).WithDuplicate | Should Be 1
    }

    It 'finds ZIPs nested inside a selected folder at their real target path' {
        $folder = Join-Path $script:source 'batch'
        New-Item -ItemType Directory -Path (Join-Path $folder 'nested') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder 'top.zip'), 'top')
        [IO.File]::WriteAllText((Join-Path $folder 'nested\deep.zip'), 'deep')
        [IO.File]::WriteAllText((Join-Path $folder 'notes.txt'), 'text')
        New-Item -ItemType Directory -Path (Join-Path $script:dest1 'batch\nested') -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $script:dest1 'batch\nested\deep.zip'), 'existing')

        $check = Get-ZipDuplicateCheck -Sources @($folder) -Destinations @($script:dest1)

        @($check.Reports).Count | Should Be 2
        $deep = @($check.Reports | Where-Object { $_.Name -eq 'deep.zip' })[0]
        @($deep.Matches).Count | Should Be 1
        $deep.Matches[0].Path | Should Be (Join-Path $script:dest1 'batch\nested\deep.zip')
        $top = @($check.Reports | Where-Object { $_.Name -eq 'top.zip' })[0]
        @($top.Matches).Count | Should Be 0
    }

    It 'ignores non-ZIP sources entirely' {
        $text = Join-Path $script:source 'notes.txt'
        [IO.File]::WriteAllText($text, 'text')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'notes.txt'), 'text')

        $check = Get-ZipDuplicateCheck -Sources @($text) -Destinations @($script:dest1)

        @($check.Reports).Count | Should Be 0
        (Get-ZipDuplicateCounts @($check.Reports)).Total | Should Be 0
    }

    It 'treats a missing destination folder as having no duplicates' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'archive')
        $missing = Join-Path $script:root 'not-created-yet'

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($missing)

        @($check.Reports[0].Matches).Count | Should Be 0
        @($check.Reports[0].Unconfirmed).Count | Should Be 0
    }

    It 'marks an unreadable destination as unconfirmed instead of absent' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'archive')
        $index = @{}
        $index[$script:dest1.ToLowerInvariant()] = @{
            Directory = $script:dest1
            Readable = $false
            Files = @{}
            Error = 'アクセスが拒否されました'
        }
        $targets = @(Get-ZipCopyTargets -Sources @($zip) -Destinations @($script:dest1))

        $reports = @(Get-ZipDuplicateReport -Targets $targets -Index $index)

        @($reports[0].Matches).Count | Should Be 0
        @($reports[0].Unconfirmed).Count | Should Be 1
        (Format-ZipDuplicateSummary $reports[0]) | Should Match '未確認'
        (Format-ZipDuplicateSummary $reports[0]) | Should Not Match 'なし'
    }

    It 'indexes each destination folder only once' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'archive')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'photos.zip'), 'existing')

        $index = Get-DestinationFileIndex -Directories @($script:dest1, $script:dest1, $script:dest1.ToUpperInvariant())

        $index.Count | Should Be 1
        $index[$script:dest1.ToLowerInvariant()].Readable | Should Be $true
    }

    It 'formats details with the duplicate path and size state' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'new')
        [IO.File]::WriteAllText((Join-Path $script:dest1 'photos.zip'), 'old-content')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1)
        $details = Format-ZipDuplicateDetails @($check.Reports)

        $details | Should Match 'photos\.zip'
        $details | Should Match '同名・サイズ違い'
        $details | Should Match ([regex]::Escape((Join-Path $script:dest1 'photos.zip')))
    }

    It 'returns an empty detail block when nothing is duplicated' {
        $zip = Join-Path $script:source 'photos.zip'
        [IO.File]::WriteAllText($zip, 'archive')

        $check = Get-ZipDuplicateCheck -Sources @($zip) -Destinations @($script:dest1)

        (Format-ZipDuplicateDetails @($check.Reports)) | Should Be ''
    }
}
