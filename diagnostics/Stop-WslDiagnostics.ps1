param([string]$Directory)

$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot '../modules/WslDiagnostics') -Force -ErrorAction Stop
    if ($Directory) {
        Stop-WslDiagnosticsTraces -Directory $Directory
    }
    elseif ($env:SETUP_WSL_DIAGNOSTICS_PATH -or $env:RUNNER_TEMP) {
        Stop-WslDiagnosticsTraces
    }
}
catch {
    Write-Host "WSL diagnostics: cleanup skipped ($($_.Exception.Message))"
}
finally {
    # GitHub's pwsh wrapper propagates LASTEXITCODE even when no exception was thrown.
    $global:LASTEXITCODE = 0
}
