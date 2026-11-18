function Get-CopyWork {
    param([string[]]$Sources)
    $count = 0
    [double]$work = 0
    $fileList = New-Object System.Collections.ArrayList
    foreach ($source in $Sources) {
        if ([IO.File]::Exists($source)) { $files = @($source) }
        elseif ([IO.Directory]::Exists($source)) { $files = [IO.Directory]::EnumerateFiles($source, '*', [IO.SearchOption]::AllDirectories) }
        else { continue }
        foreach ($file in $files) {
            $count++
            $work += ([IO.FileInfo]$file).Length + 1
            [void]$fileList.Add([string]$file)
        }
    }
    return @{ Count = $count; Work = $work; Files = $fileList }
}

function Read-SourceListFile {
    param([string]$Path)

    if (-not $Path) { throw 'ソースリストファイルが指定されていません。' }
    $manifestPath = [string]$Path
    if (-not [IO.Path]::IsPathRooted($manifestPath)) {
        $manifestPath = [IO.Path]::GetFullPath((Join-Path (Get-Location).Path $manifestPath))
    }
    if (-not [IO.File]::Exists($manifestPath)) {
        throw 'ソースリストファイルが見つかりません: ' + $manifestPath
    }

    try {
        $json = [IO.File]::ReadAllText($manifestPath, [Text.Encoding]::UTF8)
        $manifest = $json | ConvertFrom-Json
    } catch {
        throw 'ソースリストをUTF-8 JSONとして読み込めません: ' + $_.Exception.Message
    }

    if ($null -eq $manifest -or -not $manifest.PSObject.Properties['sources']) {
        throw 'ソースリストに sources 配列がありません。'
    }
    $raw = $manifest.sources
    if ($null -eq $raw) { throw 'sources が空です。' }
    if ($raw -isnot [System.Array]) {
        throw 'sources は文字列の配列で指定してください。'
    }

    $paths = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($item in $raw) {
        if ($item -isnot [string]) {
            throw 'sources には文字列のパスだけを指定してください。'
        }
        $value = ([string]$item).Trim().Replace('/', '\')
        if (-not $value) { throw 'sources に空のパスがあります。' }
        if ($value -notmatch '^([A-Za-z]:\\|\\\\)') {
            throw 'sources にはフルパスを指定してください: ' + $value
        }
        try {
            $full = [IO.Path]::GetFullPath($value)
        } catch {
            throw 'パスが不正です: ' + $value
        }
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
        if (-not (Test-Path -LiteralPath $full)) {
            throw 'コピー元が見つかりません: ' + $full
        }
        $key = $full.ToLowerInvariant()
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            [void]$paths.Add($full)
        }
    }
    if ($paths.Count -eq 0) { throw 'sources が空です。' }
    return @($paths)
}

function Merge-SourcePaths {
    param(
        [string[]]$CommandLineSources,
        [string[]]$ManifestSources
    )

    $sources = New-Object System.Collections.ArrayList
    $seen = @{}
    $duplicates = 0
    foreach ($source in (@($CommandLineSources) + @($ManifestSources))) {
        if (-not $source) { continue }
        if (-not (Test-Path -LiteralPath $source)) { continue }
        try {
            $item = Get-Item -LiteralPath $source -ErrorAction Stop
        } catch {
            continue
        }
        $full = [string]$item.FullName
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            $duplicates++
            continue
        }
        $seen[$key] = $true
        [void]$sources.Add($full)
    }
    return @{ Sources = @($sources); Duplicates = $duplicates }
}

function Copy-FileWithProgress {
    param([string]$Source, [string]$Destination, [scriptblock]$OnProgress)
    if (-not ('MultiDriveCopy.NativeCopy' -as [type])) {
        Add-Type -TypeDefinition @"
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
namespace MultiDriveCopy {
    public static class NativeCopy {
        private delegate uint Progress(long total, long transferred, long streamSize, long streamTransferred, uint streamNumber, uint reason, IntPtr source, IntPtr destination, IntPtr data);
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern bool CopyFileEx(string source, string destination, Progress callback, IntPtr data, IntPtr cancel, uint flags);
        public static void Copy(string source, string destination, Action<long> report) {
            Exception callbackError = null;
            Progress callback = (total, transferred, streamSize, streamTransferred, streamNumber, reason, src, dst, data) => {
                try { report(transferred); return 0; }
                catch (Exception e) { callbackError = e; return 1; }
            };
            bool success = CopyFileEx(source, destination, callback, IntPtr.Zero, IntPtr.Zero, 0);
            int error = Marshal.GetLastWin32Error();
            if (callbackError != null) throw callbackError;
            if (!success) throw new Win32Exception(error);
        }
    }
}
"@
    }
    [MultiDriveCopy.NativeCopy]::Copy($Source, $Destination, [Action[long]]$OnProgress)
}

function Get-CopyFileCount {
    param([string[]]$Sources)

    $count = 0
    foreach ($source in $Sources) {
        if ([IO.File]::Exists($source)) {
            $count++
        }
        elseif ([IO.Directory]::Exists($source)) {
            $count += @([IO.Directory]::EnumerateFiles($source, '*', [IO.SearchOption]::AllDirectories)).Count
        }
    }
    return $count
}

function Get-MissingDestinationDirectories {
    param([string[]]$Paths)

    $missing = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($path in $Paths) {
        if (-not [IO.Directory]::Exists($path) -and -not $seen.ContainsKey($path)) {
            [void]$seen.Add($path, $true)
            [void]$missing.Add($path)
        }
    }
    return @($missing)
}

function Get-PresetSettings {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Save-PresetSettings {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Presets,
        [string]$LastSelectedPreset,
        [System.Collections.IDictionary]$PresetDrives = $null,
        [System.Collections.IDictionary]$PresetRecycle = $null
    )

    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $presetData = @($Presets.Keys | ForEach-Object {
        $entry = @{ name = $_; path = $Presets[$_] }
        if ($PresetDrives -and $PresetDrives.Contains($_)) {
            $drives = @($PresetDrives[$_] | Where-Object { $_ })
            if ($drives.Count) { $entry['drives'] = $drives }
        }
        if ($PresetRecycle -and $PresetRecycle.Contains($_) -and $PresetRecycle[$_]) {
            $entry['recycle'] = $true
        }
        $entry
    })
    $data = @{ presets = $presetData; lastSelectedPreset = $LastSelectedPreset } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $data, (New-Object Text.UTF8Encoding($false)))
}

function Resolve-CopyDestinations {
    param(
        [string[]]$Sources,
        [string]$RelativePath,
        [string[]]$DriveLetters
    )

    $letters = @($DriveLetters | Where-Object { $_ })
    if (-not $letters.Count) {
        throw 'コピー先ドライブを選んでください。'
    }

    $destinations = New-Object System.Collections.ArrayList
    foreach ($letter in $letters) {
        $root = $letter + ':\'
        if (-not (Test-Path -LiteralPath $root)) {
            throw 'ドライブが存在しません: ' + $root
        }
        if ($RelativePath) {
            $root = Join-Path $root $RelativePath
        }
        [void]$destinations.Add($root)
        foreach ($source in $Sources) {
            $full = [IO.Path]::GetFullPath([string]$source).TrimEnd('\')
            $target = [IO.Path]::GetFullPath((Join-Path $root ([IO.Path]::GetFileName($full)))).TrimEnd('\')
            if ($full.Equals($target, [StringComparison]::OrdinalIgnoreCase) -or
                $target.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
                throw 'コピー元自身・コピー元配下へのコピーはできません: ' + $target
            }
        }
    }
    return @($destinations)
}

function ConvertTo-ShortcutFileName {
    param([string]$Name)

    $safe = [string]$Name
    foreach ($invalid in [IO.Path]::GetInvalidFileNameChars()) {
        $safe = $safe.Replace([string]$invalid, '_')
    }
    $safe = $safe.Trim()
    while ($safe.EndsWith('.')) {
        $safe = $safe.Substring(0, $safe.Length - 1).TrimEnd()
    }
    if (-not $safe) { $safe = 'preset' }
    return $safe
}

function Sync-PresetSendToShortcuts {
    param(
        [string]$TargetScript,
        [object[]]$Presets,
        [string]$SendToPath
    )

    if (-not $TargetScript -or -not (Test-Path -LiteralPath $TargetScript)) { return }
    $sendTo = $SendToPath
    if (-not $sendTo) { $sendTo = [Environment]::GetFolderPath('SendTo') }
    if (-not $sendTo -or -not (Test-Path -LiteralPath $sendTo)) { return }

    $prefix = 'E F G に一括コピー - '
    $recyclePrefix = 'E F G に一括コピー（検証してごみ箱へ） - '
    Get-ChildItem -LiteralPath $sendTo -Filter ($prefix + '*.lnk') -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
    Get-ChildItem -LiteralPath $sendTo -Filter ($recyclePrefix + '*.lnk') -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $shell = New-Object -ComObject WScript.Shell
    $used = @{}
    foreach ($preset in @($Presets)) {
        if ($null -eq $preset) { continue }
        $name = [string]$preset.name
        if (-not $name -or $name -match '[\r\n"]') { continue }
        $recycle = [bool]$preset.recycle

        $baseName = ConvertTo-ShortcutFileName $name
        $fileName = $baseName
        $suffix = 2
        while ($used.ContainsKey($fileName.ToLowerInvariant())) {
            $fileName = '{0} ({1})' -f $baseName, $suffix
            $suffix++
        }
        $used[$fileName.ToLowerInvariant()] = $true

        $shortcutPath = Join-Path $sendTo (($(if ($recycle) { $recyclePrefix } else { $prefix })) + $fileName + '.lnk')
        $link = $shell.CreateShortcut($shortcutPath)
        $link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $link.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $TargetScript + '" -Preset "' + $name + '"'
        $link.WorkingDirectory = Split-Path -Parent $TargetScript
        $link.IconLocation = "$env:SystemRoot\System32\shell32.dll,3"
        if ($recycle) {
            $link.Description = '選択したファイル・フォルダを ' + $name + ' のコピー先へ一括コピーし、検証後に元データをごみ箱へ移動'
        } else {
            $link.Description = '選択したファイル・フォルダを ' + $name + ' のコピー先へ一括コピー'
        }
        $link.Save()
    }
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
}

function Get-PathKey {
    param([string]$Path)
    $full = [IO.Path]::GetFullPath([string]$Path)
    if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
    return $full.ToLowerInvariant()
}

function Test-SourceOverlap {
    param([string[]]$Sources)

    $entries = New-Object System.Collections.ArrayList
    foreach ($source in @($Sources)) {
        if (-not $source) { continue }
        try { $item = Get-Item -LiteralPath $source -ErrorAction Stop } catch { continue }
        $full = [string]$item.FullName
        if ($full.Length -gt 3) { $full = $full.TrimEnd('\') }
        [void]$entries.Add([pscustomobject]@{
            Path = $full
            Key = $full.ToLowerInvariant()
            IsDirectory = $item.PSIsContainer
        })
    }
    for ($i = 0; $i -lt $entries.Count; $i++) {
        for ($j = $i + 1; $j -lt $entries.Count; $j++) {
            $first = $entries[$i]
            $second = $entries[$j]
            $firstPrefix = if ($first.Key.EndsWith('\')) { $first.Key } else { $first.Key + '\' }
            $secondPrefix = if ($second.Key.EndsWith('\')) { $second.Key } else { $second.Key + '\' }
            if ($first.IsDirectory -and ($second.Key -eq $first.Key -or $second.Key.StartsWith($firstPrefix, [StringComparison]::OrdinalIgnoreCase))) {
                return $true
            }
            if ($second.IsDirectory -and ($first.Key -eq $second.Key -or $first.Key.StartsWith($secondPrefix, [StringComparison]::OrdinalIgnoreCase))) {
                return $true
            }
        }
    }
    return $false
}

function Test-SourceUnderDestination {
    param(
        [string[]]$Sources,
        [string[]]$Destinations
    )

    $destinationKeys = @()
    foreach ($destination in @($Destinations)) {
        if (-not $destination) { continue }
        $key = Get-PathKey $destination
        $prefix = if ($key.EndsWith('\')) { $key } else { $key + '\' }
        $destinationKeys += [pscustomobject]@{ Key = $key; Prefix = $prefix }
    }
    foreach ($source in @($Sources)) {
        if (-not $source) { continue }
        $sourceKey = Get-PathKey $source
        $sourcePrefix = if ($sourceKey.EndsWith('\')) { $sourceKey } else { $sourceKey + '\' }
        foreach ($destination in $destinationKeys) {
            if ($sourceKey -eq $destination.Key -or $sourceKey.StartsWith($destination.Prefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
            if ($destination.Key.StartsWith($sourcePrefix, [StringComparison]::OrdinalIgnoreCase)) {
                return $true
            }
        }
    }
    return $false
}

function Get-SourceTree {
    param([string]$Root)

    $directories = New-Object System.Collections.ArrayList
    $files = New-Object System.Collections.ArrayList
    $unsafe = $false
    if (-not [IO.Directory]::Exists($Root)) {
        return @{ Directories = $directories; Files = $files; Unsafe = $true }
    }
    try {
        $rootInfo = Get-Item -LiteralPath $Root -Force -ErrorAction Stop
        if ($rootInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            return @{ Directories = $directories; Files = $files; Unsafe = $true }
        }
        $stack = New-Object System.Collections.Stack
        $stack.Push([string]$Root)
        while ($stack.Count -gt 0) {
            $directory = [string]$stack.Pop()
            [void]$directories.Add($directory)
            try {
                $entries = [IO.Directory]::EnumerateFileSystemEntries($directory)
            } catch {
                $unsafe = $true
                continue
            }
            foreach ($entry in $entries) {
                try {
                    $info = Get-Item -LiteralPath $entry -Force -ErrorAction Stop
                } catch {
                    $unsafe = $true
                    continue
                }
                if ($info.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $unsafe = $true
                    continue
                }
                if ($info.PSIsContainer) { $stack.Push([string]$entry) }
                else { [void]$files.Add([string]$entry) }
            }
        }
    } catch {
        $unsafe = $true
    }
    return @{ Directories = $directories; Files = $files; Unsafe = $unsafe }
}

function Get-FolderVerification {
    param(
        [string[]]$SourceFolders,
        [object[]]$FileResults,
        [object[]]$DirectoryMap,
        [int]$DestinationCount,
        [scriptblock]$OnProgress
    )

    $results = New-Object System.Collections.ArrayList
    $seen = @{}
    $index = 0
    foreach ($folder in @($SourceFolders)) {
        if (-not $folder) { continue }
        $folderKey = Get-PathKey $folder
        if ($seen.ContainsKey($folderKey)) { continue }
        $seen[$folderKey] = $true
        $index++
        if ($OnProgress) { & $OnProgress $index $folder }

        $result = [pscustomobject]@{
            Kind = 'Folder'
            Source = [string]$folder
            Size = 0
            SourceHash = ''
            Destinations = @()
            Action = ''
            Status = 'Protected'
            Reason = ''
            FileCount = 0
            DirectoryCount = 0
            Children = @()
            Directories = @()
            DestinationCount = $DestinationCount
        }
        try {
            if (-not [IO.Directory]::Exists($folder)) {
                $result.Reason = 'コピー元フォルダが見つかりません'
                [void]$results.Add($result)
                continue
            }
            $tree = Get-SourceTree $folder
            if ($tree.Unsafe) {
                $result.Reason = 'ジャンクションまたはシンボリックリンクが含まれているため移動できません'
                [void]$results.Add($result)
                continue
            }

            $currentDirs = @($tree.Directories | ForEach-Object { [string]$_ })
            $currentDirKeys = @{}
            foreach ($directory in $currentDirs) { $currentDirKeys[(Get-PathKey $directory)] = $true }
            $result.DirectoryCount = $currentDirs.Count

            $dirRows = New-Object System.Collections.ArrayList
            $dirsOk = $true
            foreach ($directory in $currentDirs) {
                $rows = @($DirectoryMap | Where-Object { (Get-PathKey ([string]$_.Source)) -eq (Get-PathKey $directory) })
                $destinations = New-Object System.Collections.ArrayList
                $destinationSeen = @{}
                $actions = New-Object System.Collections.ArrayList
                foreach ($row in $rows) {
                    $destination = [string]$row.Destination
                    $destinationKey = Get-PathKey $destination
                    if (-not $destinationSeen.ContainsKey($destinationKey)) {
                        $destinationSeen[$destinationKey] = $true
                        [void]$destinations.Add($destination)
                    }
                    if ($row.Action -and -not $actions.Contains([string]$row.Action)) {
                        [void]$actions.Add([string]$row.Action)
                    }
                }
                if ($destinations.Count -ne $DestinationCount) {
                    $result.Reason = 'ディレクトリのコピー先が不足しています: ' + $directory
                    $dirsOk = $false
                    break
                }
                foreach ($destination in $destinations) {
                    if (-not [IO.Directory]::Exists($destination)) {
                        $result.Reason = 'コピー先ディレクトリが見つかりません: ' + $destination
                        $dirsOk = $false
                        break
                    }
                }
                if (-not $dirsOk) { break }
                [void]$dirRows.Add([pscustomobject]@{
                    Source = $directory
                    Destinations = @($destinations)
                    Action = ($actions -join ', ')
                })
            }
            if (-not $dirsOk) {
                [void]$results.Add($result)
                continue
            }

            $folderPrefix = $folder.TrimEnd('\') + '\'
            foreach ($row in $DirectoryMap) {
                $rowSource = [string]$row.Source
                if ($rowSource -eq $folder -or $rowSource.StartsWith($folderPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                    if (-not $currentDirKeys.ContainsKey((Get-PathKey $rowSource))) {
                        $result.Reason = 'コピー後に削除・変更されたディレクトリがあります: ' + $rowSource
                        $dirsOk = $false
                        break
                    }
                }
            }
            if (-not $dirsOk) {
                [void]$results.Add($result)
                continue
            }

            $currentFiles = @($tree.Files | ForEach-Object { [string]$_ })
            $currentFileKeys = @{}
            foreach ($file in $currentFiles) { $currentFileKeys[(Get-PathKey $file)] = $true }
            $result.FileCount = $currentFiles.Count
            $children = New-Object System.Collections.ArrayList
            $totalSize = 0
            $filesOk = $true
            foreach ($file in $currentFiles) {
                $fileResult = @($FileResults | Where-Object { (Get-PathKey ([string]$_.Source)) -eq (Get-PathKey $file) }) | Select-Object -First 1
                if (-not $fileResult) {
                    $result.Reason = '検証結果のないファイルがあります: ' + $file
                    $filesOk = $false
                    break
                }
                if ($fileResult.Status -ne 'Verified') {
                    $result.Reason = 'ファイル検証に失敗しました: ' + $file + ' (' + $fileResult.Status + ')'
                    $filesOk = $false
                    break
                }
                [void]$children.Add($fileResult)
                $totalSize += [double]$fileResult.Size
            }
            if ($filesOk) {
                foreach ($fileResult in @($FileResults)) {
                    $fileSource = [string]$fileResult.Source
                    if ($fileSource.StartsWith($folderPrefix, [StringComparison]::OrdinalIgnoreCase)) {
                        if (-not $currentFileKeys.ContainsKey((Get-PathKey $fileSource))) {
                            $result.Reason = 'コピー後に削除・変更されたファイルがあります: ' + $fileSource
                            $filesOk = $false
                            break
                        }
                    }
                }
            }
            if (-not $filesOk) {
                [void]$results.Add($result)
                continue
            }

            $rootRow = @($dirRows | Where-Object { (Get-PathKey ([string]$_.Source)) -eq $folderKey }) | Select-Object -First 1
            if (-not $rootRow) {
                $result.Reason = 'フォルダ自身のコピー先がありません'
                [void]$results.Add($result)
                continue
            }

            $result.Children = @($children)
            $result.Directories = @($dirRows)
            $result.Size = $totalSize
            $result.FileCount = $children.Count
            $result.DirectoryCount = $dirRows.Count
            $result.Destinations = @($rootRow.Destinations)
            $result.Action = [string]$rootRow.Action
            $result.Status = 'Verified'
        } catch {
            $result.Status = 'Protected'
            $result.Reason = $_.Exception.Message
        }
        [void]$results.Add($result)
    }
    return @($results)
}

function Test-FolderResultStillValid {
    param($Result)

    try {
        if (-not [IO.Directory]::Exists($Result.Source)) { return $false }
        $tree = Get-SourceTree $Result.Source
        if ($tree.Unsafe) { return $false }

        $currentDirs = @{}
        foreach ($directory in @($tree.Directories)) { $currentDirs[(Get-PathKey ([string]$directory))] = $true }
        $recordedDirs = @($Result.Directories)
        if ($currentDirs.Count -ne $recordedDirs.Count) { return $false }
        foreach ($dirRow in $recordedDirs) {
            if (-not $currentDirs.ContainsKey((Get-PathKey ([string]$dirRow.Source)))) { return $false }
            if (-not [IO.Directory]::Exists([string]$dirRow.Source)) { return $false }
            if (@($dirRow.Destinations).Count -ne $Result.DestinationCount) { return $false }
            foreach ($destination in @($dirRow.Destinations)) {
                if (-not [IO.Directory]::Exists([string]$destination)) { return $false }
            }
        }

        $currentFiles = @{}
        foreach ($file in @($tree.Files)) { $currentFiles[(Get-PathKey ([string]$file))] = $true }
        $children = @($Result.Children)
        if ($currentFiles.Count -ne $children.Count) { return $false }
        foreach ($child in $children) {
            if (-not $currentFiles.ContainsKey((Get-PathKey ([string]$child.Source)))) { return $false }
            if (-not (Test-VerifiedResultStillValid $child)) { return $false }
        }

        if (@($Result.Destinations).Count -ne $Result.DestinationCount) { return $false }
        foreach ($destination in @($Result.Destinations)) {
            if (-not [IO.Directory]::Exists([string]$destination)) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Move-VerifiedFolderToRecycleBin {
    param($Result)

    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch {}
    if (-not (Test-FolderResultStillValid $Result)) {
        $Result.Status = 'Changed'
        $Result.Reason = '検証後にコピー元フォルダまたはコピー先が変更されました'
        return 'Changed'
    }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
            $Result.Source,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
        $Result.Status = 'Moved'
        $Result.Reason = 'フォルダをごみ箱へ移動しました'
        foreach ($child in @($Result.Children)) {
            $child.Status = 'Moved'
            $child.Reason = 'フォルダと一緒にごみ箱へ移動しました'
        }
        return 'Moved'
    } catch {
        $Result.Status = 'MoveFailed'
        $Result.Reason = 'ごみ箱へ移動できませんでした: ' + $_.Exception.Message
        return 'Failed'
    }
}

function Move-VerifiedItemsToRecycleBin {
    param(
        [object[]]$Results,
        [scriptblock]$OnProgress
    )

    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch {}
    $folderCandidates = @($Results | Where-Object { $_.Kind -eq 'Folder' } | ForEach-Object { [string]$_.Source })
    $ordered = @($Results | Sort-Object @{ Expression = { if ($_.Kind -eq 'Folder') { 0 } else { 1 } } }, @{ Expression = { ([string]$_.Source).Length } })
    $moved = 0
    $failed = 0
    $changed = 0
    $index = 0
    foreach ($result in $ordered) {
        if ($result.Status -ne 'Verified') { continue }
        $index++
        if ($OnProgress) { & $OnProgress $index $result.Source }

        $insideFolder = $false
        foreach ($folder in $folderCandidates) {
            if ([string]$folder -eq [string]$result.Source) { continue }
            $prefix = $folder.TrimEnd('\') + '\'
            if (([string]$result.Source).StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $insideFolder = $true
                break
            }
        }
        if ($insideFolder) {
            $result.Status = 'Protected'
            $result.Reason = '親フォルダと一緒に扱うため個別移動しません'
            continue
        }

        if ($result.Kind -eq 'Folder') {
            switch (Move-VerifiedFolderToRecycleBin $result) {
                'Moved' { $moved++ }
                'Changed' { $changed++ }
                'Failed' { $failed++ }
            }
        } else {
            switch (Move-VerifiedFileToRecycleBin $result) {
                'Moved' { $moved++ }
                'Changed' { $changed++ }
                'Failed' { $failed++ }
            }
        }
    }
    return @{ Moved = $moved; Failed = $failed; Changed = $changed }
}

function Get-CopyVerification {
    param(
        [string[]]$SourceFiles,
        [object[]]$CopyMap,
        [int]$DestinationCount,
        [scriptblock]$OnProgress
    )

    $results = New-Object System.Collections.ArrayList
    $seen = @{}
    $index = 0
    foreach ($source in @($SourceFiles)) {
        $key = ([string]$source).ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $index++
        if ($OnProgress) { & $OnProgress $index $source }

        $result = [pscustomobject]@{
            Kind = 'File'
            Source = [string]$source
            Size = 0
            SourceHash = ''
            Destinations = @()
            Action = ''
            Status = 'Protected'
            Reason = ''
        }
        try {
            if (-not [IO.File]::Exists($source)) {
                $result.Reason = 'コピー元が見つかりません'
                [void]$results.Add($result)
                continue
            }
            $sourceInfo = Get-Item -LiteralPath $source
            if ($sourceInfo.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $result.Reason = 'シンボリックリンク等の再解析ポイントは移動できません'
                [void]$results.Add($result)
                continue
            }
            $result.Size = $sourceInfo.Length
            $result.SourceHash = Get-FileSha256 $source

            $rows = @($CopyMap | Where-Object { [string]$_.Source -eq [string]$source })
            $destinations = New-Object System.Collections.ArrayList
            $destinationSeen = @{}
            $actions = New-Object System.Collections.ArrayList
            foreach ($row in $rows) {
                $destination = [string]$row.Destination
                $destinationKey = $destination.ToLowerInvariant()
                if (-not $destinationSeen.ContainsKey($destinationKey)) {
                    $destinationSeen[$destinationKey] = $true
                    [void]$destinations.Add($destination)
                }
                if ($row.Action -and -not $actions.Contains([string]$row.Action)) {
                    [void]$actions.Add([string]$row.Action)
                }
            }
            $result.Action = ($actions -join ', ')

            if ($destinations.Count -ne $DestinationCount) {
                $result.Reason = 'コピー先の数が不足しています'
                [void]$results.Add($result)
                continue
            }

            $result.Destinations = @($destinations)
            $verified = $true
            foreach ($destination in $destinations) {
                if (-not [IO.File]::Exists($destination)) {
                    $verified = $false
                    $result.Reason = 'コピー先が見つかりません: ' + $destination
                    break
                }
                $destinationInfo = Get-Item -LiteralPath $destination
                if ($destinationInfo.Length -ne $sourceInfo.Length) {
                    $verified = $false
                    $result.Reason = 'ファイルサイズが一致しません: ' + $destination
                    break
                }
                $destinationHash = Get-FileSha256 $destination
                if ($destinationHash -ne $result.SourceHash) {
                    $verified = $false
                    $result.Reason = 'SHA-256が一致しません: ' + $destination
                    break
                }
            }
            if ($verified) {
                $result.Status = 'Verified'
            } else {
                $result.Status = 'Mismatch'
            }
        } catch {
            $result.Status = 'Protected'
            $result.Reason = $_.Exception.Message
        }
        [void]$results.Add($result)
    }
    return @($results)
}

function Test-VerifiedResultStillValid {
    param($Result)

    try {
        if (-not [IO.File]::Exists($Result.Source)) { return $false }
        $sourceInfo = Get-Item -LiteralPath $Result.Source
        if ($sourceInfo.Length -ne $Result.Size) { return $false }
        if ((Get-FileSha256 $Result.Source) -ne $Result.SourceHash) { return $false }

        foreach ($destination in @($Result.Destinations)) {
            if (-not [IO.File]::Exists($destination)) { return $false }
            $destinationInfo = Get-Item -LiteralPath $destination
            if ($destinationInfo.Length -ne $Result.Size) { return $false }
            if ((Get-FileSha256 $destination) -ne $Result.SourceHash) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Move-VerifiedFileToRecycleBin {
    param($Result)

    try { Add-Type -AssemblyName Microsoft.VisualBasic -ErrorAction Stop } catch {}
    if (-not (Test-VerifiedResultStillValid $Result)) {
        $Result.Status = 'Changed'
        $Result.Reason = '検証後にコピー元またはコピー先が変更されました'
        return 'Changed'
    }
    try {
        [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
            $Result.Source,
            [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs,
            [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        )
        $Result.Status = 'Moved'
        $Result.Reason = 'ごみ箱へ移動しました'
        return 'Moved'
    } catch {
        $Result.Status = 'MoveFailed'
        $Result.Reason = 'ごみ箱へ移動できませんでした: ' + $_.Exception.Message
        return 'Failed'
    }
}

function Get-VerificationSummary {
    param([object[]]$Results)

    if ($null -eq $Results) { $items = @() } else { $items = @($Results) }
    $verified = @($items | Where-Object { $_.Status -eq 'Verified' })
    $moved = @($items | Where-Object { $_.Status -eq 'Moved' })
    $mismatch = @($items | Where-Object { $_.Status -eq 'Mismatch' })
    $protected = @($items | Where-Object { $_.Status -eq 'Protected' })
    $changed = @($items | Where-Object { $_.Status -eq 'Changed' })
    $failed = @($items | Where-Object { $_.Status -eq 'MoveFailed' })
    $candidateSize = ($verified | Measure-Object -Property Size -Sum).Sum
    if ($null -eq $candidateSize) { $candidateSize = 0 }

    return @{
        Total = $items.Count
        Verified = $verified.Count
        Moved = $moved.Count
        Mismatch = $mismatch.Count
        Protected = $protected.Count
        Changed = $changed.Count
        Failed = $failed.Count
        CandidateSize = [double]$candidateSize
    }
}

function Format-FileSize {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N1} KB' -f ($Bytes / 1KB)) }
    return ([string][long]$Bytes + ' B')
}

function Write-VerificationLog {
    param(
        [string]$Path,
        [object[]]$Results,
        $Summary,
        [object[]]$FileResults
    )

    $directory = Split-Path -Parent $Path
    if ($directory) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $builder = New-Object System.Text.StringBuilder
    [void]$builder.AppendLine('Multi Drive Copy 検証ログ')
    [void]$builder.AppendLine('生成日時: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    [void]$builder.AppendLine('対象: ' + $Summary.Total + ' 件 / 検証成功: ' + $Summary.Verified + ' 件 / 移動済み: ' + $Summary.Moved + ' 件')
    [void]$builder.AppendLine('不一致: ' + $Summary.Mismatch + ' 件 / 保護: ' + $Summary.Protected + ' 件 / 変更: ' + $Summary.Changed + ' 件 / 移動失敗: ' + $Summary.Failed + ' 件')
    [void]$builder.AppendLine('移動可能サイズ: ' + (Format-FileSize $Summary.CandidateSize))
    [void]$builder.AppendLine('')
    foreach ($result in @($Results)) {
        $kind = if ($result.Kind -eq 'Folder') { 'フォルダ' } else { 'ファイル' }
        [void]$builder.AppendLine('[' + $result.Status + '] [' + $kind + '] ' + $result.Source)
        [void]$builder.AppendLine('  サイズ: ' + $result.Size + ' / 操作: ' + $result.Action)
        if ($result.Kind -eq 'Folder') {
            [void]$builder.AppendLine('  内訳: ファイル ' + $result.FileCount + ' / ディレクトリ ' + $result.DirectoryCount)
        }
        if ($result.SourceHash) { [void]$builder.AppendLine('  SHA-256: ' + $result.SourceHash) }
        foreach ($destination in @($result.Destinations)) {
            [void]$builder.AppendLine('  コピー先: ' + $destination)
        }
        if ($result.Reason) { [void]$builder.AppendLine('  詳細: ' + $result.Reason) }
        [void]$builder.AppendLine('')
    }
    if (@($FileResults).Count -gt 0) {
        [void]$builder.AppendLine('## ファイル単位の検証')
        foreach ($result in @($FileResults)) {
            [void]$builder.AppendLine('[' + $result.Status + '] ' + $result.Source)
            [void]$builder.AppendLine('  サイズ: ' + $result.Size + ' / 操作: ' + $result.Action)
            [void]$builder.AppendLine('  SHA-256: ' + $result.SourceHash)
            foreach ($destination in @($result.Destinations)) {
                [void]$builder.AppendLine('  コピー先: ' + $destination)
            }
            if ($result.Reason) { [void]$builder.AppendLine('  詳細: ' + $result.Reason) }
            [void]$builder.AppendLine('')
        }
    }
    [void]$builder.AppendLine('リトライ手順:')
    [void]$builder.AppendLine('- 検証できなかったファイル/フォルダと不一致のファイル/フォルダはコピー元に残しています。')
    [void]$builder.AppendLine('- 移動に失敗した場合はごみ箱が利用できることを確認し、もう一度コピーと検証を実行してください。')
    [void]$builder.AppendLine('- ごみ箱が利用できない環境では完全削除に切り替えず、手動で確認してください。')
    [IO.File]::WriteAllText($Path, $builder.ToString(), (New-Object Text.UTF8Encoding($true)))
}
