$scriptRoot = Split-Path -Parent $PSScriptRoot
$scripts = @(
    'MultiDriveCopy.Core.ps1',
    'MultiDriveCopy.ps1'
    'Install.ps1'
    'Uninstall.ps1'
)

Describe 'PowerShell 5.1 compatibility' {
    It 'runs under Windows PowerShell 5.1' {
        $PSVersionTable.PSVersion.Major | Should Be 5
        $PSVersionTable.PSVersion.Minor | Should Be 1
    }

    foreach ($scriptName in $scripts) {
        It "stores $scriptName as UTF-8 with a BOM" {
            $bytes = [IO.File]::ReadAllBytes((Join-Path $scriptRoot $scriptName))

            $bytes[0] | Should Be 0xEF
            $bytes[1] | Should Be 0xBB
            $bytes[2] | Should Be 0xBF
        }

        It "parses $scriptName without syntax errors" {
            $tokens = $null
            $errors = $null

            [void][System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $scriptRoot $scriptName),
                [ref]$tokens,
                [ref]$errors
            )

            $errors.Count | Should Be 0
        }
    }
}
