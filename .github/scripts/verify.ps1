param(
    [string]$WslIpOutput,
    [string]$DistributionOutput
)

$ErrorActionPreference = 'Stop'

$expectedBridgeSubnet = '10.11.0.0/24'

# --- Assertion helpers -------------------------------------------------------

function Assert-Equal {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)]$Expected,
        [Parameter(Mandatory = $true)]$Actual,
        # Case-sensitive, because some checks compare values that differ only in case or escaping.
        [switch]$CaseSensitive
    )

    $isEqual = if ($CaseSensitive) { $Actual -ceq $Expected } else { $Actual -eq $Expected }
    if (-not $isEqual) {
        throw "${Description}: expected '$Expected', got '$Actual'"
    }
}

function Assert-Throws {
    param(
        [Parameter(Mandatory = $true)][string]$Description,
        [Parameter(Mandatory = $true)][scriptblock]$Action,
        [Parameter(Mandatory = $true)][string]$MessagePattern
    )

    $message = $null
    try {
        & $Action | Out-Null
    }
    catch {
        $message = $_.Exception.Message
    }

    if ($message -notmatch $MessagePattern) {
        throw "${Description}: expected an error matching '$MessagePattern', got: $message"
    }
}

# wsl.exe emits UTF-16, which arrives here with embedded NUL characters.
function Get-WslOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Command
    )

    $output = Invoke-Wsl -CheckExitCode -Command $Command
    return ($output -replace "`0", "").Trim()
}

# --- Environment checks ------------------------------------------------------

function Show-ActionOutputsAndEnvironment {
    Write-Host "wsl-ip = $WslIpOutput"
    Write-Host "distribution = $DistributionOutput"
    Write-Host "WSL_IP env = $Env:WSL_IP"
    Write-Host "WSL_DISTRIBUTION env = $Env:WSL_DISTRIBUTION"
    Write-Host "WSL_TOOLS_MODULE_PATH env = $Env:WSL_TOOLS_MODULE_PATH"
}

function Test-WslIpEnvironmentVariableIsSet {
    if (-not $Env:WSL_IP) {
        throw "WSL_IP environment variable not set"
    }
}

# --- Docker checks -----------------------------------------------------------

function Test-DockerIsRunningInWsl {
    Write-Host "Verifying Docker is running inside WSL ($Env:WSL_DISTRIBUTION)..."

    # Dogfood: omit -Distribution so it defaults to $WSL_DISTRIBUTION.
    $serverVersion = Get-WslOutput "docker info --format '{{.ServerVersion}}'"
    Write-Host "Docker server version: $serverVersion"
}

# setup.ps1 pins the bridge subnet in /etc/docker/daemon.json. Docker's default 172.17.0.0/16
# overlaps WSL2's random NAT subnet (172.16.0.0/12) and breaks host->container port publishing.
function Test-DockerBridgeSubnetIsPinned {
    Write-Host "Verifying the Docker bridge subnet is pinned to $expectedBridgeSubnet..."

    $actualSubnet = Get-WslOutput "docker network inspect bridge --format '{{(index .IPAM.Config 0).Subnet}}'"
    Write-Host "Docker bridge subnet: $actualSubnet"

    Assert-Equal "Docker bridge subnet" -Expected $expectedBridgeSubnet -Actual $actualSubnet
}

function Test-DockerIsAvailableOnLinuxRunner {
    Write-Host "Linux runner — verifying Docker is available..."

    $serverVersion = docker info --format '{{.ServerVersion}}'
    if ($LASTEXITCODE -ne 0) {
        throw "Docker is not available on the runner"
    }
    Write-Host "Docker server version: $serverVersion"
}

# --- Invoke-DockerCompose checks ---------------------------------------------

# `config` only renders the file, so no image is pulled.
# The directory name contains a space on purpose.
function New-ComposeProbeFile {
    $directory = Join-Path $Env:RUNNER_TEMP "wsl tools compose check"
    New-Item -ItemType Directory -Path $directory -Force | Out-Null

    $filePath = Join-Path $directory "compose.yml"
    Set-Content -Path $filePath -Value @'
name: wsltools-check
services:
  probe:
    image: busybox
    environment:
      PROBE_VALUE: "${PROBE_VALUE:?PROBE_VALUE is required}"
'@

    return $filePath
}

function Test-ComposeCheckExitCodeThrowsOnFailure {
    param(
        [Parameter(Mandatory = $true)][string]$ComposeFilePath
    )

    Write-Host "Verifying Invoke-DockerCompose -CheckExitCode throws when Compose fails (PROBE_VALUE not set)..."

    Assert-Throws "Invoke-DockerCompose -CheckExitCode" -MessagePattern "failed with exit code" -Action {
        Invoke-DockerCompose -CheckExitCode -ComposeFilePath $ComposeFilePath -Arguments "config"
    }
}

function Test-ComposeEnvironmentIsPassedThrough {
    param(
        [Parameter(Mandatory = $true)][string]$ComposeFilePath
    )

    Write-Host "Verifying Invoke-DockerCompose passes -Environment through to Compose..."

    # Shell metacharacters on purpose: quoting, expansion, backticks and backslashes must all survive.
    $probeValue = 'it''s a "quoted" $HOME `value` \\ end'

    $config = Invoke-DockerCompose -CheckExitCode -ComposeFilePath $ComposeFilePath `
        -Arguments "config", "--format", "json" `
        -Environment @{ PROBE_VALUE = $probeValue }

    # `config` escapes `$` as `$$` in its output.
    $renderedValue = ($config | ConvertFrom-Json).services.probe.environment.PROBE_VALUE -replace '\$\$', '$'
    Assert-Equal "PROBE_VALUE in the compose config" -Expected $probeValue -Actual $renderedValue -CaseSensitive
}

function Test-ComposeEnvironmentDoesNotLeak {
    if (Test-Path Env:PROBE_VALUE) {
        throw "Invoke-DockerCompose left PROBE_VALUE in the process environment"
    }
}

# --- ConvertTo-WslPath checks ------------------------------------------------

function Test-ConvertToWslPath {
    Write-Host "Verifying ConvertTo-WslPath..."

    $cases = @(
        @{ Windows = 'D:\a\foo\bar.sh'; Wsl = '/mnt/d/a/foo/bar.sh' }
        @{ Windows = '\\?\D:\a\foo\bar.sh'; Wsl = '/mnt/d/a/foo/bar.sh' }
        @{ Windows = 'C:\'; Wsl = '/mnt/c/' }
    )

    foreach ($case in $cases) {
        Assert-Equal "ConvertTo-WslPath '$($case.Windows)'" -Expected $case.Wsl -Actual (ConvertTo-WslPath $case.Windows) -CaseSensitive
    }
}

# --- Run ---------------------------------------------------------------------

Show-ActionOutputsAndEnvironment
Test-WslIpEnvironmentVariableIsSet

# Dogfood: import the module this action ships for consumers, on both OSes.
Import-Module $Env:WSL_TOOLS_MODULE_PATH

if ($Env:RUNNER_OS -eq "Windows") {
    Test-DockerIsRunningInWsl
    Test-DockerBridgeSubnetIsPinned
}
else {
    Test-DockerIsAvailableOnLinuxRunner
}

Test-ConvertToWslPath

# Dogfood: Invoke-DockerCompose on both OSes.
$composeFilePath = New-ComposeProbeFile
Test-ComposeCheckExitCodeThrowsOnFailure -ComposeFilePath $composeFilePath
Test-ComposeEnvironmentIsPassedThrough -ComposeFilePath $composeFilePath
Test-ComposeEnvironmentDoesNotLeak
