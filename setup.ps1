param (
    [string]$Distribution = "Debian",
    [string]$Memory = "4GB"
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'modules' 'WslTools'
Import-Module $modulePath -Force

function Export-Env {
    param([string]$Name, [string]$Value)
    "$Name=$Value" | Out-File -FilePath $env:GITHUB_ENV -Encoding utf8 -Append
}

function Export-Output {
    param([string]$Name, [string]$Value)
    if ($env:GITHUB_OUTPUT) {
        "$Name=$Value" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }
}

$runnerOs = $Env:RUNNER_OS ?? "Linux"

if ($runnerOs -eq "Linux") {
    Write-Output "Linux runner — WSL provisioning is not needed. Docker is already available."

    # Set env vars so consuming actions can use the same interface unconditionally.
    Export-Env -Name "WSL_DISTRIBUTION" -Value ""
    Export-Env -Name "WSL_IP" -Value "127.0.0.1"

    Export-Output -Name "wsl-ip" -Value "127.0.0.1"
    Export-Output -Name "distribution" -Value ""
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Windows runner — provisioning WSL2 with Docker"

    # Override via environment variables for consistency with existing actions.
    $wslDistribution = $Env:WSL_DISTRIBUTION_OVERRIDE ?? $Distribution
    $wslMemory = $Env:WSL_MEMORY_OVERRIDE ?? $Memory

    # 1. Constrain the WSL2 VM (memory + prevent idle shutdown).
    #    Only write if the file doesn't exist so local development configs are preserved.
    $wslConfigPath = Join-Path $Env:USERPROFILE ".wslconfig"
    if (-not (Test-Path $wslConfigPath)) {
        Write-Output "Writing $wslConfigPath (memory=$wslMemory) to constrain the WSL2 VM"
        Set-Content -Path $wslConfigPath -Value "[wsl2]`nmemory=$wslMemory`nvmIdleTimeout=-1" -Encoding ASCII
    }

    # 2. Enable WSL2.
    wsl.exe --set-default-version 2 | Out-Null

    # 3. Install the distribution if it is not already registered.
    Write-Output "::group::Preparing WSL ($wslDistribution)"

    $installedDistributions = ((wsl.exe --list --quiet) -replace "`0", "") |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }

    if ($installedDistributions -notcontains $wslDistribution) {
        Write-Output "Installing $wslDistribution in WSL"
        wsl.exe --install $wslDistribution --web-download --no-launch
        if ($LASTEXITCODE -ne 0) {
            throw "Failed to install $wslDistribution in WSL"
        }
    }
    else {
        Write-Output "$wslDistribution is already installed"
    }

    # 4. Ensure Docker is installed inside the WSL distribution.
    Write-Output "Ensuring Docker is installed inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v docker >/dev/null 2>&1 || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes docker.io; }"

    # 5. Start the Docker daemon (systemd if available, otherwise SysV).
    Write-Output "Starting Docker daemon inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker info >/dev/null 2>&1 || { if [ -d /run/systemd/system ]; then systemctl start docker; else service docker start; fi; }"

    # 6. Keep the WSL instance alive for the rest of the job.
    #    WSL terminates an instance when no processes remain under its init (PID 2);
    #    a plain background process (e.g. sleep) does not prevent this, but a D-Bus
    #    session bus launched through `wsl --exec` does. vmIdleTimeout above covers
    #    the VM-level idle timeout; this covers the separate instance-level shutdown.
    Write-Output "Starting a D-Bus session to keep the WSL instance alive for the job"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v dbus-launch >/dev/null 2>&1 || { apt-get update && apt-get install -y dbus-x11; }; command -v dbus-launch >/dev/null 2>&1 || { echo 'dbus-launch is unavailable after installing dbus-x11' >&2; exit 1; }"
    wsl.exe --distribution $wslDistribution --user root --exec /usr/bin/dbus-launch true
    if ($LASTEXITCODE -ne 0) {
        throw "dbus-launch keep-alive failed with exit code $LASTEXITCODE"
    }

    Write-Output "::endgroup::"

    # 7. Detect the WSL VM gateway IPv4 address.
    $wslIp = ((wsl.exe --distribution $wslDistribution --user root -- hostname -I) -replace "`0", "").Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1

    if (-not $wslIp) {
        throw "Could not determine the WSL IPv4 address"
    }

    Write-Output "WSL address: $wslIp"

    # 8. Export env vars and outputs for consuming actions.
    Export-Env -Name "WSL_DISTRIBUTION" -Value $wslDistribution
    Export-Env -Name "WSL_IP" -Value $wslIp

    Export-Output -Name "wsl-ip" -Value $wslIp
    Export-Output -Name "distribution" -Value $wslDistribution
}
else {
    throw "$runnerOs not supported"
}