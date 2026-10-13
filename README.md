# setup-wsl-action

Provisions WSL2 and Docker on a GitHub Actions Windows runner. On Linux runners, the action is a no-op (Docker is already available).

Designed for the Particular `setup-*-action` pattern, where a service-specific action (e.g. `setup-ibmmq-action`) needs to run a Linux Docker container on a Windows runner. This action handles the WSL2 provisioning once, so each service action doesn't have to duplicate it.

## Usage

```yaml
steps:
  - name: Setup WSL
    uses: Particular/setup-wsl-action@v1
    id: wsl
    with:
      distribution: Ubuntu
      memory: 4GB
  - name: Run my service
    shell: pwsh
    run: |
      Import-Module $Env:WSL_TOOLS_MODULE_PATH
      # -Distribution defaults to $WSL_DISTRIBUTION, so it can be omitted.
      Invoke-Wsl -CheckExitCode -Command "docker run --name myservice --detach --publish 1433:1433 myimage"
      # Connection string uses $WSL_IP as the host on Windows
```

The action sets three environment variables for subsequent steps:

| Variable | Windows | Linux |
|---|---|---|
| `WSL_DISTRIBUTION` | The distribution name (e.g. `Ubuntu`) | Empty string |
| `WSL_IP` | The WSL VM gateway IPv4 address | `127.0.0.1` |
| `WSL_TOOLS_MODULE_PATH` | Path to the shipped `WslTools` module (`Invoke-Wsl`) | Same path (importable; `Invoke-Wsl` is Windows-only) |

Service actions can read these env vars to run Docker commands through WSL and construct connection strings with the correct host, without doing their own WSL provisioning. `WSL_TOOLS_MODULE_PATH` lets a consuming action `Import-Module` the shipped `Invoke-Wsl` helper instead of copying it into its own repo. If the env vars are not set (e.g. the action wasn't called), service actions can fall back to provisioning WSL themselves. That keeps existing actions backwards-compatible.

## Inputs

| Input | Required | Default | Description |
|---|:-:|:-:|---|
| `distribution` | No | `Ubuntu` | The WSL distribution to install. Ubuntu is recommended (reliable upstream CDN). Debian is supported but its WSL artifact is currently unreliable upstream (`salsa.debian.org`); see [microsoft/WSL#41279](https://github.com/microsoft/WSL/issues/41279). |
| `memory` | No | `4GB` | The memory limit for the WSL2 VM. Increase for memory-intensive services. |
| `enable-cache` | No | `true` | Whether to cache the provisioned WSL distribution across runs via `@actions/cache`. On hit, restores a `wsl --export` tar with `wsl --import`, skipping the distro download and Docker install. Defaults to `true`. |

The following environment variables can also override the inputs, for consistency with existing Particular setup actions:

| Variable | Default | Description |
|---|---|---|
| `WSL_DISTRIBUTION_OVERRIDE` | `Ubuntu` | Override the distribution name. |
| `WSL_MEMORY_OVERRIDE` | `4GB` | Override the WSL2 VM memory limit. |

## Outputs

| Output | Description |
|---|---|
| `wsl-ip` | The WSL VM gateway IPv4 address. On Linux runners this is `127.0.0.1`. |
| `distribution` | The WSL distribution name that was provisioned. Empty on Linux runners. |
| `wsl-tools-module-path` | Filesystem path to the shipped `WslTools` module (`Invoke-Wsl`), for consuming actions to `Import-Module`. Set on both Windows and Linux runners. |
| `cache-hit` | `'true'` if the WSL distribution was restored from cache, `'false'` otherwise (including on Linux runners). |

## Exported module (`Invoke-Wsl`)

This action ships a small PowerShell module, `WslTools`, exposing `Invoke-Wsl`, the same helper the action uses internally. Its path is exported as `WSL_TOOLS_MODULE_PATH` (env) / `wsl-tools-module-path` (output) so consuming `setup-*-action`s can reuse it without copying a `.psm1` into every repo:

```powershell
Import-Module $Env:WSL_TOOLS_MODULE_PATH
Invoke-Wsl -CheckExitCode -Command "docker run --name myservice --detach --publish 1433:1433 myimage"
```

`Invoke-Wsl` runs a bash command inside the provisioned distribution as root:

| Parameter | Required | Description |
|---|:-:|---|
| `-Command` | Yes | The bash command to run inside the distribution. |
| `-Distribution` | No | Defaults to `$WSL_DISTRIBUTION` (set by this action), so it can usually be omitted. |
| `-CheckExitCode` | No | Throw on a non-zero exit code. |

`Invoke-Wsl` wraps `wsl.exe`, so it is Windows-only. On Linux runners, Docker is native and consuming actions run it directly. The module path is still exported so the `Import-Module` line is identical on both OSes.

The module also exports `ConvertTo-WslPath`, which turns a Windows path (e.g. `D:\a\foo\bar.sh`) into the equivalent path inside the WSL distribution (e.g. `/mnt/d/a/foo/bar.sh`). This is useful when a consuming action needs to pass a host-side file, such as an init script, into WSL. It is also Windows-only.

## What it does (Windows)

1. Writes `%USERPROFILE%\.wslconfig` with `[wsl2]` + `memory=<N>GB` + `vmIdleTimeout=-1`. This constrains the VM and prevents idle shutdown. Only writes if the file doesn't exist (local dev configs are preserved).
2. Logs runner image, Windows build, virtualization indicators, Windows feature states, and WSL version/status. Validates WSL2 prerequisites, then selects WSL2 (`wsl --set-default-version 2`); selecting the default does not enable Windows features.
3. Installs the distribution if not already registered. For Ubuntu, resolves the image URL and SHA-256 from Microsoft's manifest, downloads and verifies the image, then installs it with `wsl --install --from-file <image.wsl> --name Ubuntu --no-launch`. Debian retains `wsl --install Debian --no-launch`; cache hits retain `wsl --import`.
4. Installs Docker inside the distribution (`apt-get install docker.io`).
5. Pins Docker's bridge and network pools to `10.x` via `/etc/docker/daemon.json`, so they can't overlap WSL2's randomly assigned NAT subnet (`172.16.0.0/12`).
6. Starts the Docker daemon (systemd or SysV service), restarting if systemd already started it at VM boot so the pinned subnets are applied.
7. Launches a D-Bus session bus to keep the WSL instance alive for the rest of the job (WSL terminates instances when no processes remain under its init).
8. Detects the WSL VM gateway IPv4 address via `hostname -I`.
9. Sets `WSL_DISTRIBUTION`, `WSL_IP`, and `WSL_TOOLS_MODULE_PATH` environment variables and action outputs.

### Caching

The action caches a `wsl --export` tar of the fully-provisioned distribution (Docker included) keyed on `setup-wsl-<distro>-distro<distroImageSha256[:16]>-setup<sha256(setup.ps1)[:16]>`. The distro image hash comes from Microsoft's [`DistributionInfo.json`](https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json), the same manifest `wsl --install` resolves against, so the cache refreshes automatically when a new distro image is published. This keeps the base image current for security updates. On a cache hit it imports the tar with `wsl --import`, skipping the download and the Docker install. The cache is subject to the 10 GB per-repository GitHub Actions limit (LRU + weekly eviction). Disable with `enable-cache: false`.

### Troubleshooting provisioning hangs

The `WSL runner diagnostics and prerequisites` log group records the image (`ImageOS`/`ImageVersion`), Windows build, exposed virtualization flags, feature states, and WSL version/status. WSL2 requires `VirtualMachinePlatform` to be enabled. Inbox WSL additionally requires `Microsoft-Windows-Subsystem-Linux`; modern Store/MSI WSL2 does not require that legacy feature. Required features in a pending state fail with reboot guidance. The action does not enable features or reboot the runner during a job. General Windows servicing/update reboot markers produce a warning, not an automatic rejection.

Virtualization flags can be masked inside hosted virtual machines, so they are diagnostic only. Checked WSL commands and an explicit first boot (`/bin/true`) validate operational readiness.

Windows feature queries require administrator privileges. When running locally without elevation, the action logs those states as unknown and uses operational WSL checks instead, so an already working installation is not rejected just because DISM cannot query its features.

Each provisioning command logs its start and completion, exit code, and elapsed time. For a stuck run, find the last `Starting:` message without a matching completion:

- **Version/status, default version, or distribution enumeration:** investigate the runner image and WSL installation/service.
- **Resolve Ubuntu image manifest / Download Ubuntu image:** investigate GitHub's manifest endpoint or Ubuntu's image source. Downloads use the hosted runner's `curl.exe` progress meter, three attempts with five-second delays, a 30-second connection timeout, and a 60-second low-speed limit (below 1 KiB/s). Each manifest attempt is capped at 60 seconds; each image attempt at 10 minutes. Failed attempts discard partial files.
- **Verify Ubuntu image SHA-256:** a mismatch fails before installation; investigate the upstream artifact or manifest.
- **Install from verified local Ubuntu image:** downloading and verification have already completed; investigate the local WSL installer.
- **Download and install Debian:** investigate Debian's distribution source or WSL installer.
- **Import from cache:** investigate the cached image and WSL import/storage path.
- **First boot:** investigate WSL2 VM startup and nested virtualization.
- **A WSL bash command:** use the preceding setup phase message to distinguish package installation, Docker startup, and other Linux-side operations.

Compare affected and successful runs by image and WSL version before changing installation behavior. A job timeout is a safety net, not a root-cause fix. CI covers Ubuntu and Debian on Windows with caching enabled and disabled, plus the Linux no-op path. One additional Ubuntu job provisions with caching enabled, unregisters the distribution, then runs setup again and requires a cache hit before verifying Docker, Compose, and the bridge subnet.

### Diagnosing local installation stalls and resource contention

Set `SETUP_WSL_DIAGNOSTICS: 'true'` on the setup action's step to enable diagnostics around distribution installation, cache import, and explicit first boot. Downloads and their flags are unchanged. With diagnostics disabled (the default), provisioning retains its existing synchronous execution path.

The diagnostic mode periodically logs host CPU utilization, available/committed memory, disk I/O and free space, and selected WSL/VM and .NET build processes. Process CPU is cumulative, so compare consecutive samples; command lines and environment variables are not collected. Samples and operation timestamps are also saved under `${{ runner.temp }}/setup-wsl-diagnostics`.

On elevated Windows runners it additionally records a narrow WSL/VM-compute ETW trace, using circular files capped at 128 MB per operation. This starts before installation/import/first boot so an early stall is captured, rather than waiting for a presumed timeout. Collection failures warn without failing provisioning. Traces are stopped when the monitored command finishes, but a runner-enforced step timeout can bypass cleanup. Add the following **separate steps after setup** to stop any interrupted action-owned traces and upload the files:

```yaml
- name: Setup WSL with diagnostics
  id: wsl
  uses: Particular/setup-wsl-action@v1
  env:
    SETUP_WSL_DIAGNOSTICS: 'true'
  with:
    memory: 8GB
    enable-cache: false
- name: Stop interrupted traces
  if: always() && runner.os == 'Windows'
  shell: pwsh
  run: |
    if ($env:SETUP_WSL_DIAGNOSTICS_CLEANUP_PATH) {
      & $env:SETUP_WSL_DIAGNOSTICS_CLEANUP_PATH
    }
- name: Upload WSL diagnostics
  if: always() && runner.os == 'Windows'
  uses: actions/upload-artifact@v7.0.2
  with:
    name: wsl-diagnostics
    path: ${{ env.SETUP_WSL_DIAGNOSTICS_PATH }}
    retention-days: 7
```

Diagnostic mode exports `SETUP_WSL_DIAGNOSTICS_CLEANUP_PATH` and `SETUP_WSL_DIAGNOSTICS_PATH` before provisioning, so the later cleanup and upload steps do not depend on a successful setup and use the original directory even if setup overrides `RUNNER_TEMP`. Hard job cancellation or runner loss may prevent even `always()` steps from executing; this cannot guarantee trace recovery. Diagnostic artifacts can contain paths and WSL error details: review them before sharing, and do not publish unredacted traces externally.

The manually dispatched **WSL installation diagnostics** workflow leaves regular CI unchanged and compares four cases: fresh installation versus local exported-image import, each with the same synthetic .NET graph-build workload running concurrently or completed beforehand. Serial cases build for at least two minutes before provisioning; concurrent cases repeat the same build command until provisioning finishes, so a slow download does not remove contention before installation. Total build iterations can therefore differ; use their timestamps and process samples to confirm actual overlap. It disables remote cache reuse, ensures Ubuntu is unregistered, uses 8 GB in each case, and uploads samples/traces even on step failure. The imported image is prepared before the measured workload; import performs less work than a fresh install.

This synthetic workload is **not the ServiceControl build** and cannot prove its resource-starvation hypothesis. For the decisive comparison in the consuming repository, use the same commit, runner image, memory limit, and build command with `enable-cache: false` in both cases, moving the build wait before setup only in the serial case. Repeat both cases and correlate installation timing with telemetry and WSL traces. An 8 GB WSL limit is not an upfront reservation; masked processor virtualization flags alone do not establish missing virtualization support.

The explicit Ubuntu download is a diagnostic experiment to avoid opaque installer-managed download stalls, not a proven root-cause fix or a speed optimization. Store-managed downloads may be faster. Download and local installation timings are logged separately; temporary manifest/image files are removed after success or failure.

## What it does (Linux)

Nothing. Docker is already available on the runner. Sets `WSL_IP=127.0.0.1` and `WSL_DISTRIBUTION` to empty, so consuming actions can use the same interface unconditionally.

## Limitations

This action is designed for Particular's CI `setup-*-action` pattern. It is public, but external users should understand it is opinionated for this specific use case.

- **GitHub Actions hosted Windows runners only.** Requires WSL2 with nested virtualization. Will not work on self-hosted runners without WSL2, macOS, or other CI systems.
- **Fresh Ubuntu installation requires modern WSL with `--install --from-file` support and `curl.exe`.** An unsupported WSL version fails with upgrade guidance rather than silently reverting to the opaque download path. Cache imports and Debian retain their existing installation paths.
- **Default distribution is Ubuntu.** Distribution images are fetched from each distro's own infrastructure (Ubuntu from `releases.ubuntu.com`, Debian from `salsa.debian.org`), which is outside our control. Debian's WSL artifact on `salsa.debian.org` is currently serving inconsistent bytes and fails `Wsl/InstallDistro/VerifyChecksum/TRUST_E_BAD_DIGEST`, so Ubuntu (Canonical's release CDN) is the default and recommended; Debian remains selectable but may be unreliable until upstream is fixed ([microsoft/WSL#41279](https://github.com/microsoft/WSL/issues/41279)). The provisioned distribution is cached via `wsl --export`/`wsl --import` (keyed on the distro image hash from Microsoft's manifest and a hash of `setup.ps1`), so subsequent runs skip the download and the Docker install.
- **Installs Docker via the distribution's `docker.io` apt package**, not Docker's official repositories. May lag behind official Docker releases.
- **Pins Docker's bridge subnet to `10.x`.** Docker's defaults (bridge `172.17.0.0/16`, pools up to `172.30.0.0/16`) overlap WSL2's randomly assigned NAT range (`172.16.0.0/12`), intermittently breaking host→container port forwarding when the NAT lands on `172.17.x`. Tools inside the distro that hardcode `172.17.0.0/16` will need updating.
- **Writes `%USERPROFILE%\.wslconfig` if it doesn't exist.** Won't overwrite an existing file. This is a side effect on the runner.
- **D-Bus keep-alive is a workaround** for WSL's idle shutdown behavior. It may break with future WSL versions.
- **No cleanup of the WSL distribution after the job.** On hosted runners the VM is destroyed. On self-hosted runners the distribution persists and accumulates.
- **Defaults to 4GB WSL VM memory.** Services with higher memory requirements need to override this.
- **Single distribution only.** No multi-distro support.

## Local development

Install dependencies and build the bundle:

```bash
npm install
npm run prepare
```

The `prepare` script runs `@vercel/ncc` to bundle `index.mjs` and its dependencies into `dist/index.mjs`. The committed `dist/` is what the runner executes. The source `index.mjs` is not used directly.

To test `setup.ps1` directly:

```bash
$Env:RUNNER_OS=Windows
.\setup.ps1 -Distribution Ubuntu -Memory 4GB
```

Open the folder in Visual Studio Code with the DevContainer for a consistent development environment with Node.js, Docker-in-Docker, and PowerShell.

## License

MIT