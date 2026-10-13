param (
    [string]$Distribution = "Ubuntu",
    [string]$Memory = "4GB",
    [string]$ImportFromCache,
    [string]$ExportToCache
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

function Invoke-WslSetupCommand {
    param(
        [string]$Operation,
        [string[]]$Arguments,
        [switch]$CaptureOutput,
        [switch]$AllowFailure
    )

    # Inspect exit codes ourselves, including the unsupported --version probe on inbox WSL.
    $PSNativeCommandUseErrorActionPreference = $false
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "[$([DateTime]::UtcNow.ToString('o'))] Starting: $Operation"
    try {
        $output = @()
        if ($CaptureOutput) {
            $output = @(wsl.exe @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", "" })
        }
        else {
            wsl.exe @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", "" } | Out-Host
        }
        $exitCode = $LASTEXITCODE
        Write-Host "Completed: $Operation (exit code $exitCode, $($timer.Elapsed.TotalSeconds.ToString('F1'))s)"
        if ($exitCode -ne 0 -and -not $AllowFailure) {
            $output | Out-Host
            throw "$Operation failed with exit code $exitCode. See the runner and WSL diagnostics above."
        }
        if ($CaptureOutput) {
            return [pscustomobject]@{ Output = $output; ExitCode = $exitCode }
        }
    }
    catch {
        Write-Host "Failed: $Operation ($($timer.Elapsed.TotalSeconds.ToString('F1'))s)"
        throw
    }
}

function Assert-WslPrerequisites {
    Write-Host "::group::WSL runner diagnostics and prerequisites"
    try {
        Write-Host "Runner image: $env:ImageOS; version: $env:ImageVersion"
        Write-Host "Starting: Windows build and virtualization diagnostics"
        $windows = Get-CimInstance Win32_OperatingSystem
        $computer = Get-CimInstance Win32_ComputerSystem
        $processors = Get-CimInstance Win32_Processor
        Write-Host "Windows: $($windows.Caption); version: $($windows.Version); build: $($windows.BuildNumber)"
        Write-Host "HypervisorPresent: $($computer.HypervisorPresent)"
        foreach ($processor in $processors) {
            # These flags can be masked by a host hypervisor; WSL commands validate usability below.
            Write-Host "Processor virtualization: firmware=$($processor.VirtualizationFirmwareEnabled); VM monitor extensions=$($processor.VMMonitorModeExtensions); SLAT=$($processor.SecondLevelAddressTranslationExtensions)"
        }
        Write-Host "Completed: Windows build and virtualization diagnostics"

        $features = @{}
        foreach ($name in @('VirtualMachinePlatform', 'Microsoft-Windows-Subsystem-Linux')) {
            Write-Host "Starting: Query Windows feature $name"
            $features[$name] = (Get-WindowsOptionalFeature -Online -FeatureName $name).State.ToString()
            Write-Host "Completed: Query Windows feature $name (state=$($features[$name]))"
        }

        $rebootPending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
            (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
        Write-Host "Windows servicing/update reboot pending: $rebootPending"
        if ($rebootPending) {
            Write-Warning "Windows has a pending servicing/update reboot. This alone does not establish that WSL is unusable."
        }

        # WSL2 always needs VirtualMachinePlatform, including Store/MSI installations.
        if ($features['VirtualMachinePlatform'] -match 'Pending') {
            throw "VirtualMachinePlatform is $($features['VirtualMachinePlatform']). Reboot the runner before provisioning WSL2; this action cannot reboot a running job."
        }
        if ($features['VirtualMachinePlatform'] -ne 'Enabled') {
            throw "WSL2 requires the VirtualMachinePlatform Windows feature to be enabled and the runner rebooted before this job. Check runner image $env:ImageOS/$env:ImageVersion."
        }

        Get-Command wsl.exe -ErrorAction Stop | Out-Null
        $version = Invoke-WslSetupCommand -Operation 'Detect WSL version (Store/MSI or inbox)' -Arguments @('--version') -CaptureOutput -AllowFailure
        $version.Output | Out-Host
        if ($version.ExitCode -ne 0) {
            Write-Host "WSL --version is unavailable; checking inbox WSL prerequisites."
            # Unlike modern Store/MSI WSL2, inbox WSL also needs the legacy WSL feature.
            if ($features['Microsoft-Windows-Subsystem-Linux'] -match 'Pending') {
                throw "The inbox WSL feature is $($features['Microsoft-Windows-Subsystem-Linux']). Reboot the runner before provisioning."
            }
            if ($features['Microsoft-Windows-Subsystem-Linux'] -ne 'Enabled') {
                throw "WSL --version failed and the inbox WSL feature is not enabled. Preinstall Store/MSI WSL, or enable Microsoft-Windows-Subsystem-Linux and reboot before this job."
            }
        }

        Invoke-WslSetupCommand -Operation 'Check WSL status' -Arguments @('--status')
    }
    finally {
        Write-Host "::endgroup::"
    }
}

$runnerOs = $Env:RUNNER_OS ?? "Linux"

if ($runnerOs -eq "Linux") {
    Write-Output "Linux runner — WSL provisioning is not needed. Docker is already available."

    # Set env vars so consuming actions can use the same interface unconditionally.
    Export-Env -Name "WSL_DISTRIBUTION" -Value ""
    Export-Env -Name "WSL_IP" -Value "127.0.0.1"
    Export-Env -Name "WSL_TOOLS_MODULE_PATH" -Value $modulePath

    Export-Output -Name "wsl-ip" -Value "127.0.0.1"
    Export-Output -Name "distribution" -Value ""
    Export-Output -Name "wsl-tools-module-path" -Value $modulePath
}
elseif ($runnerOs -eq "Windows") {
    Write-Output "Windows runner — provisioning WSL2 with Docker"

    # Override via environment variables for consistency with existing actions.
    $wslDistribution = $Env:WSL_DISTRIBUTION_OVERRIDE ?? $Distribution
    $wslMemory = $Env:WSL_MEMORY_OVERRIDE ?? $Memory

    Assert-WslPrerequisites

    # 1. Constrain the WSL2 VM (memory + prevent idle shutdown).
    #    Only write if the file doesn't exist so local development configs are preserved.
    $wslConfigPath = Join-Path $Env:USERPROFILE ".wslconfig"
    if (-not (Test-Path $wslConfigPath)) {
        Write-Output "Writing $wslConfigPath (memory=$wslMemory) to constrain the WSL2 VM"
        Set-Content -Path $wslConfigPath -Value "[wsl2]`nmemory=$wslMemory`nvmIdleTimeout=-1" -Encoding ASCII
    }

    # 2. Select WSL2 (this does not enable Windows features).
    Invoke-WslSetupCommand -Operation 'Select WSL2 as the default version' -Arguments @('--set-default-version', '2')

    # 3. Install the distribution if it is not already registered.
    Write-Output "::group::Preparing WSL ($wslDistribution)"

    $distributionList = Invoke-WslSetupCommand -Operation 'Enumerate registered distributions' -Arguments @('--list', '--quiet') -CaptureOutput
    $installedDistributions = $distributionList.Output |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne "" }

    if ($installedDistributions -notcontains $wslDistribution) {
        if ($ImportFromCache -and (Test-Path $ImportFromCache)) {
            Write-Output "Importing $wslDistribution from cache ($ImportFromCache)"
            $importLocation = Join-Path $env:RUNNER_TEMP "setup-wsl-vhd-$wslDistribution"
            New-Item -ItemType Directory -Force -Path $importLocation | Out-Null
            Invoke-WslSetupCommand -Operation "Import $wslDistribution from cache" -Arguments @('--import', $wslDistribution, $importLocation, $ImportFromCache, '--version', '2')
        }
        else {
            # Distribution images are downloaded from each distro's own infrastructure
            # (Ubuntu from releases.ubuntu.com, Debian from salsa.debian.org), which is outside
            # our control. Uses the service-managed install (no --web-download). Debian's WSL
            # artifact on salsa.debian.org is currently serving inconsistent bytes and fails
            # Wsl/InstallDistro/VerifyChecksum/TRUST_E_BAD_DIGEST, so Ubuntu is the default.
            # See https://github.com/microsoft/WSL/issues/41279
            Write-Output "Installing $wslDistribution in WSL"
            Invoke-WslSetupCommand -Operation "Download and install $wslDistribution" -Arguments @('--install', $wslDistribution, '--no-launch')
        }
    }
    else {
        Write-Output "$wslDistribution is already installed"
    }

    Invoke-WslSetupCommand -Operation "First boot of $wslDistribution (WSL2 virtualization check)" -Arguments @('--distribution', $wslDistribution, '--user', 'root', '--exec', '/bin/true')

    # 4. Ensure Docker is installed inside the WSL distribution.
    Write-Output "Ensuring Docker is installed inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v docker >/dev/null 2>&1 || { apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install --yes docker.io; }"

    # 5. Ensure Docker Compose (v2 plugin) is installed inside the WSL distribution.
    #    The docker.io package ships the engine and CLI but not the compose plugin.
    #    The plugin package is named docker-compose-v2 on Ubuntu and docker-compose on Debian.
    Write-Output "Ensuring Docker Compose is installed inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker compose version >/dev/null 2>&1 || { apt-get update && (DEBIAN_FRONTEND=noninteractive apt-get install --yes docker-compose-v2 || DEBIAN_FRONTEND=noninteractive apt-get install --yes docker-compose); }"

    # 6. Pin Docker's bridge and network pools to 10.x. WSL2 hands the VM a random
    #    /20 from 172.16.0.0/12 on every boot, and Docker's defaults (172.17.0.0/16)
    #    live in that range, so port publishing randomly breaks when the NAT lands
    #    on 172.17.x (e.g. MQRC_HOST_NOT_AVAILABLE). Written via base64 to avoid
    #    WSL interop quoting issues.
    Write-Output "Pinning Docker bridge and network subnets to 10.x (WSL NAT uses 172.16.0.0/12)"
    $daemonJson = @'
{
  "bip": "10.11.0.1/24",
  "default-address-pools": [
    { "base": "10.12.0.0/16", "size": 24 },
    { "base": "10.13.0.0/16", "size": 24 }
  ]
}
'@
    $daemonJsonBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($daemonJson))
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "mkdir -p /etc/docker && echo $daemonJsonBase64 | base64 -d > /etc/docker/daemon.json"

    # 7. Start the Docker daemon (systemd if available, otherwise SysV). Restart
    #    rather than start — systemd may already have started Docker at VM boot,
    #    and the pinned subnets only apply after a restart.
    Write-Output "Starting Docker daemon inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "if [ -d /run/systemd/system ]; then systemctl restart docker; else service docker restart; fi"
    $bridgeSubnet = ((Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}'") -replace "`0", "").Trim()
    Write-Output "Docker bridge subnet: $bridgeSubnet"

    # 8. Ensure D-Bus is installed so the exported image is self-contained for cache hits.
    Write-Output "Ensuring dbus-x11 is installed inside $wslDistribution"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v dbus-launch >/dev/null 2>&1 || { apt-get update && apt-get install -y dbus-x11; }"

    # 9. Export the provisioned distribution to the cache tar (fresh-install path only).
    if ($ExportToCache -and -not (Test-Path $ExportToCache)) {
        Write-Output "Exporting $wslDistribution to cache ($ExportToCache)"
        Invoke-WslSetupCommand -Operation "Terminate $wslDistribution before cache export" -Arguments @('--terminate', $wslDistribution)
        $exportDir = Split-Path $ExportToCache -Parent
        if (-not (Test-Path $exportDir)) {
            New-Item -ItemType Directory -Force -Path $exportDir | Out-Null
        }
        Invoke-WslSetupCommand -Operation "Export $wslDistribution to cache" -Arguments @('--export', $wslDistribution, $ExportToCache)
    }

    # 10. Keep the WSL instance alive for the rest of the job.
    #    WSL terminates an instance when no processes remain under its init (PID 2);
    #    a plain background process (e.g. sleep) does not prevent this, but a D-Bus
    #    session bus launched through `wsl --exec` does. vmIdleTimeout above covers
    #    the VM-level idle timeout; this covers the separate instance-level shutdown.
    Write-Output "Starting a D-Bus session to keep the WSL instance alive for the job"
    Invoke-Wsl -Distribution $wslDistribution -CheckExitCode -Command "command -v dbus-launch >/dev/null 2>&1 || { apt-get update && apt-get install -y dbus-x11; }; command -v dbus-launch >/dev/null 2>&1 || { echo 'dbus-launch is unavailable after installing dbus-x11' >&2; exit 1; }"
    Invoke-WslSetupCommand -Operation "Start D-Bus keep-alive in $wslDistribution" -Arguments @('--distribution', $wslDistribution, '--user', 'root', '--exec', '/usr/bin/dbus-launch', 'true')

    Write-Output "::endgroup::"

    # 11. Detect the WSL VM gateway IPv4 address.
    $address = Invoke-WslSetupCommand -Operation "Detect $wslDistribution IPv4 address" -Arguments @('--distribution', $wslDistribution, '--user', 'root', '--', 'hostname', '-I') -CaptureOutput
    $wslIp = ($address.Output -join ' ').Trim().Split(" ", [System.StringSplitOptions]::RemoveEmptyEntries) |
        Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' } |
        Select-Object -First 1

    if (-not $wslIp) {
        throw "Could not determine the WSL IPv4 address"
    }

    Write-Output "WSL address: $wslIp"

    # 12. Export env vars and outputs for consuming actions.
    Export-Env -Name "WSL_DISTRIBUTION" -Value $wslDistribution
    Export-Env -Name "WSL_IP" -Value $wslIp
    Export-Env -Name "WSL_TOOLS_MODULE_PATH" -Value $modulePath

    Export-Output -Name "wsl-ip" -Value $wslIp
    Export-Output -Name "distribution" -Value $wslDistribution
    Export-Output -Name "wsl-tools-module-path" -Value $modulePath
}
else {
    throw "$runnerOs not supported"
}