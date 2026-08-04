function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string]$Distribution,
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$CheckExitCode
    )

    wsl.exe --distribution $Distribution --user root -- bash -c $Command

    if ($CheckExitCode -and $LASTEXITCODE -ne 0) {
        throw "WSL command failed with exit code $LASTEXITCODE`: $Command"
    }
}

Export-ModuleMember -Function Invoke-Wsl