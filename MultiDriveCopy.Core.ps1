function Get-CopyWork {
    param([string[]]$Sources)
    $count = 0
    [double]$work = 0
    foreach ($source in $Sources) {
        if ([IO.File]::Exists($source)) { $files = @($source) }
        elseif ([IO.Directory]::Exists($source)) { $files = [IO.Directory]::EnumerateFiles($source, '*', [IO.SearchOption]::AllDirectories) }
        else { continue }
        foreach ($file in $files) { $count++; $work += ([IO.FileInfo]$file).Length + 1 }
    }
    return @{ Count = $count; Work = $work }
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
        [System.Collections.IDictionary]$PresetDrives = $null
    )

    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $presetData = @($Presets.Keys | ForEach-Object {
        $entry = @{ name = $_; path = $Presets[$_] }
        if ($PresetDrives -and $PresetDrives.Contains($_)) {
            $drives = @($PresetDrives[$_] | Where-Object { $_ })
            if ($drives.Count) { $entry['drives'] = $drives }
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
    Get-ChildItem -LiteralPath $sendTo -Filter ($prefix + '*.lnk') -ErrorAction SilentlyContinue |
        ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }

    $shell = New-Object -ComObject WScript.Shell
    $used = @{}
    foreach ($preset in @($Presets)) {
        if ($null -eq $preset) { continue }
        $name = [string]$preset.name
        if (-not $name -or $name -match '[\r\n"]') { continue }

        $baseName = ConvertTo-ShortcutFileName $name
        $fileName = $baseName
        $suffix = 2
        while ($used.ContainsKey($fileName.ToLowerInvariant())) {
            $fileName = '{0} ({1})' -f $baseName, $suffix
            $suffix++
        }
        $used[$fileName.ToLowerInvariant()] = $true

        $shortcutPath = Join-Path $sendTo ($prefix + $fileName + '.lnk')
        $link = $shell.CreateShortcut($shortcutPath)
        $link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
        $link.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $TargetScript + '" -Preset "' + $name + '"'
        $link.WorkingDirectory = Split-Path -Parent $TargetScript
        $link.IconLocation = "$env:SystemRoot\System32\shell32.dll,3"
        $link.Description = '選択したファイル・フォルダを ' + $name + ' のコピー先へ一括コピー'
        $link.Save()
    }
}
