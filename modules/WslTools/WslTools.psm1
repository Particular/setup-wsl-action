function Invoke-Wsl {
    param(
        # Defaults to the distribution provisioned by setup-wsl-action ($WSL_DISTRIBUTION),
        # so consuming actions can omit it. Pass explicitly to target a different distro.
        [string]$Distribution = $env:WSL_DISTRIBUTION,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$CheckExitCode
    )

    if (-not $Distribution) {
        throw "Invoke-Wsl: -Distribution was not provided and WSL_DISTRIBUTION is not set. Run setup-wsl-action first or pass -Distribution explicitly."
    }

    wsl.exe --distribution $Distribution --user root -- bash -c $Command

    if ($CheckExitCode -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed with exit code $LASTEXITCODE`: $Command"
    }
}

Export-ModuleMember -Function Invoke-Wsl