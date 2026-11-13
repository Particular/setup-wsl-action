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

# Convert a Windows path (e.g. "D:\a\foo\bar.sh" or "\\?\D:\foo\bar.sh") to the equivalent
# path inside the default WSL distribution (e.g. "/mnt/d/a/foo/bar.sh"). We do this in pure
# PowerShell rather than round-tripping through `wsl.exe -- wslpath -u` because the WSL
# interop arg parser mangles the backslashes when a Windows path is passed as a single argv
# element (the path arrives at the WSL side as a slash-less string).
function ConvertTo-WslPath {
    param(
        [Parameter(Mandatory = $true)][string]$WindowsPath
    )

    if ($WindowsPath -notmatch '^[A-Za-z]:') {
        throw "ConvertTo-WslPath expects a Windows-style absolute path with a drive letter, got: $WindowsPath"
    }

    # Strip the extended-length \\?\ prefix and the drive letter, normalise separators.
    $trimmed = $WindowsPath -replace '^\\\\\?\\', ''
    $drive = $trimmed.Substring(0, 1).ToLowerInvariant()
    $rest = $trimmed.Substring(2) -replace '\\', '/'
    return "/mnt/$drive/$rest"
}

function ConvertTo-BashSingleQuoted {
    param(
        [string]$Value
    )

    return "'" + $Value.Replace("'", "'\''") + "'"
}

function Invoke-DockerCompose {
    param(
        [Parameter(Mandatory = $true)][string]$ComposeFilePath,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [System.Collections.IDictionary]$Environment = @{},
        [string]$Distribution = $env:WSL_DISTRIBUTION,
        [switch]$CheckExitCode
    )

    foreach ($name in $Environment.Keys) {
        if ($name -notmatch '^[A-Za-z_][A-Za-z0-9_]*\z') {
            throw "Invoke-DockerCompose: '$name' is not a valid environment variable name."
        }
    }

    if ($Env:RUNNER_OS -eq 'Windows') {
        $words = @($Environment.Keys | Sort-Object | ForEach-Object { "$_=$(ConvertTo-BashSingleQuoted $Environment[$_])" })
        $words += 'docker', 'compose', '-f', (ConvertTo-BashSingleQuoted (ConvertTo-WslPath $ComposeFilePath))
        $words += $Arguments | ForEach-Object { ConvertTo-BashSingleQuoted $_ }

        # wsl.exe runs everything after `--` through the default shell before bash -c sees it, so `$`,
        # backticks and backslashes would be expanded despite the single quotes. Base64 survives that pass.
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($words -join ' '))
        Invoke-Wsl -Distribution $Distribution -Command "source <(echo $encodedCommand | base64 -d)"
    }
    else {
        $previousValues = @{}
        try {
            foreach ($name in $Environment.Keys) {
                $previousValues[$name] = [Environment]::GetEnvironmentVariable($name)
                Set-Item -Path "Env:$name" -Value "$($Environment[$name])"
            }
            docker compose -f $ComposeFilePath @Arguments
        }
        finally {
            foreach ($name in $previousValues.Keys) {
                Set-Item -Path "Env:$name" -Value $previousValues[$name]
            }
        }
    }

    # Not delegated to Invoke-Wsl: its message would contain the encoded command, and with it the environment values.
    if ($CheckExitCode -and $LASTEXITCODE -ne 0) {
        throw "docker compose $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

Export-ModuleMember -Function Invoke-Wsl, ConvertTo-WslPath, Invoke-DockerCompose