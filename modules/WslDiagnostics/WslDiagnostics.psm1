$ErrorActionPreference = 'Stop'

function Write-WslDiagnosticRecord {
    param($Context, $Record)
    try {
        $Record | ConvertTo-Json -Depth 8 -Compress |
            Add-Content -LiteralPath $Context.LogPath -Encoding utf8
    }
    catch {
        Write-Host "WSL diagnostics: could not persist a record ($($_.Exception.Message))"
    }
}

function Set-WslDiagnosticOperation {
    param($Context, [string]$State, $ExitCode = $null)
    if (-not $Context) { return }
    try {
        $record = [ordered]@{
            type = 'operation'; id = $Context.Id; operation = $Context.Operation
            startedAt = $Context.StartedAt; timestamp = [DateTime]::UtcNow.ToString('o')
            state = $State; exitCode = $ExitCode
        }
        $record | ConvertTo-Json -Compress |
            Set-Content -LiteralPath $Context.StatePath -Encoding utf8
        Write-WslDiagnosticRecord $Context $record
    }
    catch {
        Write-Host "WSL diagnostics: could not persist operation state ($($_.Exception.Message))"
    }
}

function Get-WslDiagnosticSample {
    param($Context)
    $errors = [Collections.Generic.List[string]]::new()
    $sample = [ordered]@{
        type = 'host'; id = $Context.Id; operation = $Context.Operation
        timestamp = [DateTime]::UtcNow.ToString('o')
    }
    # Select properties explicitly: never serialize CIM/process objects with command lines.
    $queries = @(
        @{ Key = 'cpu'; Class = 'Win32_PerfFormattedData_PerfOS_Processor'; Filter = "Name='_Total'"; Properties = @('PercentProcessorTime') },
        @{ Key = 'memory'; Class = 'Win32_PerfFormattedData_PerfOS_Memory'; Filter = ''; Properties = @('AvailableBytes', 'CommittedBytes', 'CommitLimit') },
        @{ Key = 'diskIO'; Class = 'Win32_PerfFormattedData_PerfDisk_PhysicalDisk'; Filter = "Name='_Total'"; Properties = @('DiskReadBytesPersec', 'DiskWriteBytesPersec') },
        @{ Key = 'disks'; Class = 'Win32_LogicalDisk'; Filter = 'DriveType=3'; Properties = @('DeviceID', 'FreeSpace', 'Size') },
        @{ Key = 'services'; Class = 'Win32_Service'; Filter = "Name='WslService' OR Name='LxssManager' OR Name='vmcompute' OR Name='hns'"; Properties = @('Name', 'State', 'StartMode') }
    )
    foreach ($query in $queries) {
        try {
            $parameters = @{
                ClassName = $query.Class; Property = $query.Properties
                OperationTimeoutSec = 2; ErrorAction = 'Stop'
            }
            if ($query.Filter) { $parameters.Filter = $query.Filter }
            $sample[$query.Key] = @(Get-CimInstance @parameters | Select-Object -Property $query.Properties)
        }
        catch {
            $sample[$query.Key] = @()
            $errors.Add("$($query.Key): $($_.Exception.Message)")
        }
    }
    $processes = [Collections.Generic.List[object]]::new()
    try {
        foreach ($process in @(Get-Process -Name 'wsl', 'wslservice', 'wslhost', 'vmmem*', 'vmcompute', 'dotnet', 'MSBuild', 'VBCSCompiler' -ErrorAction SilentlyContinue)) {
            try {
                $processes.Add([ordered]@{
                    pid = $process.Id; name = $process.ProcessName
                    cpuSeconds = $process.CPU; workingSetBytes = $process.WorkingSet64
                    privateMemoryBytes = $process.PrivateMemorySize64
                })
            }
            catch { $errors.Add("process $($process.Id): unavailable") }
        }
    }
    catch { $errors.Add("processes: $($_.Exception.Message)") }
    $sample.processes = @($processes.ToArray())
    $sample.errors = @($errors.ToArray())
    return $sample
}

function Write-WslDiagnosticSample {
    param($Context)
    if (-not $Context) { return }
    try {
        $sample = Get-WslDiagnosticSample $Context
        Write-WslDiagnosticRecord $Context $sample
        $cpu = ($sample.cpu | Select-Object -First 1).PercentProcessorTime
        $memory = $sample.memory | Select-Object -First 1
        $disk = $sample.diskIO | Select-Object -First 1
        $free = ($sample.disks | ForEach-Object { "$($_.DeviceID)=$($_.FreeSpace)B" }) -join ','
        $services = ($sample.services | ForEach-Object { "$($_.Name)=$($_.State)" }) -join ','
        Write-Host "[$($sample.timestamp)] WSL diagnostics ($($Context.Operation)): CPU=$cpu%; available=$($memory.AvailableBytes)B; committed=$($memory.CommittedBytes)/$($memory.CommitLimit)B; disk read/write=$($disk.DiskReadBytesPersec)/$($disk.DiskWriteBytesPersec)B/s; free=[$free]; processes=$($sample.processes.Count); services=[$services]; query errors=$($sample.errors.Count)"
    }
    catch { Write-Host "WSL diagnostics: host sample unavailable ($($_.Exception.Message))" }
}

function Test-WslDiagnosticAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-WslDiagnosticTrace {
    param($Context)
    # Subset of https://github.com/microsoft/WSL/blob/master/diagnostics/wsl.wprp:
    # WSL service/user and VM compute/client/worker only, without kernel, network or
    # security providers. All-keyword/verbose settings are ours, not WPR defaults.
    try {
        if (-not (Test-WslDiagnosticAdministrator)) {
            Write-Host 'WSL diagnostics: ETW skipped (requires elevation)'
            return
        }
        $name = "setup-wsl-$([Guid]::NewGuid().ToString('N'))"
        $sessionPath = Join-Path $Context.Directory "$name.session.json"
        $tracePath = Join-Path $Context.Directory "$name.etl"
        $providerPath = Join-Path $Context.Directory "$name.providers.txt"
        @(
            '{B99CDB5A-039C-5046-E672-1A0DE0A40211} 0xFFFFFFFFFFFFFFFF 5'
            '{D90B9468-67F0-5B3B-42CC-82AC81FFD960} 0xFFFFFFFFFFFFFFFF 5'
            '{17103E3F-3C6E-4677-BB17-3B267EB5BE57} 0xFFFFFFFFFFFFFFFF 5'
            '{AF7FD3A7-B248-460C-A9F5-FEC39EF8468C} 0xFFFFFFFFFFFFFFFF 5'
            '{51DDFA29-D5C8-4803-BE4B-2ECB715570FE} 0xFFFFFFFFFFFFFFFF 5'
        ) | Set-Content -LiteralPath $providerPath -Encoding ascii
        # Persist before starting so an interrupted action can stop only its own session.
        $session = [ordered]@{
            owner = 'setup-wsl-action'; name = $name; operationId = $Context.Id
            startedAt = [DateTime]::UtcNow.ToString('o'); state = 'starting'
        }
        $session | ConvertTo-Json -Compress | Set-Content -LiteralPath $sessionPath -Encoding utf8
        $Context.SessionPath = $sessionPath
        $PSNativeCommandUseErrorActionPreference = $false
        $traceOutput = & logman.exe start $name -ets -o $tracePath -f bincirc -max 128 `
            -pf $providerPath 2>&1
        $traceExitCode = $LASTEXITCODE
        $session.state = if ($traceExitCode -eq 0) { 'running' } else { 'start-failed' }
        # Keep ownership metadata unchanged while active: cancellation during a rewrite
        # must not leave cleanup unable to identify and stop an already-started session.
        Write-WslDiagnosticRecord $Context @{
            type = 'trace'; timestamp = [DateTime]::UtcNow.ToString('o')
            id = $Context.Id; state = $session.state; name = $name; exitCode = $traceExitCode
        }
        Write-Host "WSL diagnostics: ETW $($session.state) ($name, exit code $traceExitCode)"
    }
    catch { Write-Host "WSL diagnostics: ETW unavailable ($($_.Exception.Message))" }
}

function Stop-WslDiagnosticTrace {
    param([string]$SessionPath)
    try {
        $session = Get-Content -LiteralPath $SessionPath -Raw | ConvertFrom-Json
        if ($session.owner -ne 'setup-wsl-action' -or
            $session.name -cnotmatch '^setup-wsl-[a-f0-9]{32}$' -or
            [IO.Path]::GetFileName($SessionPath) -cne "$($session.name).session.json") {
            Write-Host 'WSL diagnostics: ignoring unrecognized trace session record'
            return
        }
        if ($session.state -eq 'stopped') { return }
        $PSNativeCommandUseErrorActionPreference = $false
        # Stopping an ETW session flushes its buffers to the circular ETL file.
        $traceOutput = & logman.exe stop $session.name -ets 2>&1
        $traceExitCode = $LASTEXITCODE
        $session.state = if ($traceExitCode -eq 0) { 'stopped' } else { 'stop-failed' }
        $session | Add-Member -NotePropertyName stoppedAt -NotePropertyValue ([DateTime]::UtcNow.ToString('o')) -Force
        $session | Add-Member -NotePropertyName stopExitCode -NotePropertyValue $traceExitCode -Force
        if ($traceExitCode -eq 0) {
            $session | ConvertTo-Json -Compress | Set-Content -LiteralPath $SessionPath -Encoding utf8
        }
        Write-Host "WSL diagnostics: ETW $($session.state) ($($session.name), exit code $traceExitCode)"
    }
    catch { Write-Host "WSL diagnostics: trace cleanup unavailable ($($_.Exception.Message))" }
}

function Stop-WslDiagnosticsTraces {
    param([string]$Directory)
    try {
        if (-not $Directory) {
            if ($env:SETUP_WSL_DIAGNOSTICS_PATH) { $Directory = $env:SETUP_WSL_DIAGNOSTICS_PATH }
            elseif ($env:RUNNER_TEMP) { $Directory = Join-Path $env:RUNNER_TEMP 'setup-wsl-diagnostics' }
            else { return }
        }
        if (-not (Test-Path -LiteralPath $Directory)) { return }
        foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter 'setup-wsl-*.session.json' -File)) {
            Stop-WslDiagnosticTrace -SessionPath $file.FullName
        }
        foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.operation.json' -File)) {
            try {
                $record = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json
                if ($record.state -ne 'running') { continue }
                if ($record.id -cnotmatch '^[a-f0-9]{32}$' -or
                    $file.Name -cne "$($record.id).operation.json") { continue }
                $record.state = 'interrupted'
                $record.timestamp = [DateTime]::UtcNow.ToString('o')
                $record | ConvertTo-Json -Compress | Set-Content -LiteralPath $file.FullName -Encoding utf8
                Write-WslDiagnosticRecord @{ LogPath = (Join-Path $Directory "$($record.id).jsonl") } $record
            }
            catch { Write-Host "WSL diagnostics: operation cleanup unavailable ($($_.Exception.Message))" }
        }
    }
    catch { Write-Host "WSL diagnostics: cleanup unavailable ($($_.Exception.Message))" }
}

function Invoke-WslMonitoredCommand {
    param([string]$Operation, [string[]]$Arguments, [switch]$CaptureOutput)
    $context = $null
    $job = $null
    $output = [Collections.Generic.List[string]]::new()
    $queue = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    try {
        try {
            if ($env:SETUP_WSL_DIAGNOSTICS_PATH) { $directory = $env:SETUP_WSL_DIAGNOSTICS_PATH }
            elseif ($env:RUNNER_TEMP) { $directory = Join-Path $env:RUNNER_TEMP 'setup-wsl-diagnostics' }
            else { throw 'RUNNER_TEMP is unset' }
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
            $id = [Guid]::NewGuid().ToString('N')
            $context = @{
                Directory = $directory; Id = $id; Operation = $Operation
                StartedAt = [DateTime]::UtcNow.ToString('o')
                LogPath = (Join-Path $directory "$id.jsonl")
                StatePath = (Join-Path $directory "$id.operation.json"); SessionPath = $null
            }
            Set-WslDiagnosticOperation $context 'running'
            Start-WslDiagnosticTrace $context
        }
        catch { Write-Host "WSL diagnostics: initialization unavailable ($($_.Exception.Message))" }
        try {
            $job = Start-ThreadJob -ArgumentList $Arguments, $queue -ScriptBlock {
                param($NativeArguments, $OutputQueue)
                $ErrorActionPreference = 'Stop'
                $PSNativeCommandUseErrorActionPreference = $false
                & wsl.exe @NativeArguments 2>&1 | ForEach-Object {
                    $OutputQueue.Enqueue(("$_" -replace "`0", ''))
                }
                $LASTEXITCODE
            }
        }
        catch {
            # No native command has started if creation of the worker fails.
            Write-Host "WSL diagnostics: worker unavailable; using synchronous execution ($($_.Exception.Message))"
            $PSNativeCommandUseErrorActionPreference = $false
            if ($CaptureOutput) {
                $lines = @(& wsl.exe @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", '' })
                foreach ($line in $lines) { $output.Add($line) }
            }
            else {
                & wsl.exe @Arguments 2>&1 | ForEach-Object { "$_" -replace "`0", '' } | Out-Host
            }
            $exitCode = $LASTEXITCODE
        }
        if ($job) {
            $nextSample = [DateTime]::UtcNow
            do {
                $line = $null
                while ($queue.TryDequeue([ref]$line)) {
                    if ($CaptureOutput) { $output.Add($line) } else { $line | Out-Host }
                }
                if ($job.State -in @('Completed', 'Failed', 'Stopped')) { break }
                if ([DateTime]::UtcNow -ge $nextSample) {
                    $nextSample = [DateTime]::UtcNow.AddSeconds(15)
                    Write-WslDiagnosticSample $context
                }
                Start-Sleep -Milliseconds 200
            } while ($true)
            while ($queue.TryDequeue([ref]$line)) {
                if ($CaptureOutput) { $output.Add($line) } else { $line | Out-Host }
            }
            if ($job.State -ne 'Completed') {
                throw "WSL command worker $($job.State): $($job.JobStateInfo.Reason)"
            }
            $exitCode = Receive-Job -Job $job -ErrorAction Stop
            if ($null -eq $exitCode) { throw 'WSL command worker did not return an exit code' }
        }
        Set-WslDiagnosticOperation $context $(if ($exitCode -eq 0) { 'completed' } else { 'failed' }) $exitCode
        return [pscustomobject]@{ Output = $output.ToArray(); ExitCode = $exitCode }
    }
    catch {
        Set-WslDiagnosticOperation $context 'failed'
        throw
    }
    finally {
        if ($context -and $context.SessionPath) { Stop-WslDiagnosticTrace $context.SessionPath }
        if ($job) {
            try {
                if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job -Job $job -ErrorAction Stop }
                Remove-Job -Job $job -Force -ErrorAction Stop
            }
            catch { Write-Host "WSL diagnostics: worker cleanup unavailable ($($_.Exception.Message))" }
        }
    }
}

Export-ModuleMember -Function Invoke-WslMonitoredCommand, Stop-WslDiagnosticsTraces
