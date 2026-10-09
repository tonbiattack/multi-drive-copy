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
