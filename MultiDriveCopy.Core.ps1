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
        [string]$LastSelectedPreset
    )

    New-Item -ItemType Directory -Path (Split-Path $Path) -Force | Out-Null
    $presetData = @($Presets.Keys | ForEach-Object { @{ name = $_; path = $Presets[$_] } })
    $data = @{ presets = $presetData; lastSelectedPreset = $LastSelectedPreset } | ConvertTo-Json -Depth 5
    [IO.File]::WriteAllText($Path, $data, (New-Object Text.UTF8Encoding($false)))
}
