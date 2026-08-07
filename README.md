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
2. Enables WSL2 (`wsl --set-default-version 2`).
3. Installs the distribution if not already registered (`wsl --install Ubuntu --no-launch`).
4. Installs Docker inside the distribution (`apt-get install docker.io`).
5. Starts the Docker daemon (systemd or SysV service).
6. Launches a D-Bus session bus to keep the WSL instance alive for the rest of the job (WSL terminates instances when no processes remain under its init).
7. Detects the WSL VM gateway IPv4 address via `hostname -I`.
8. Sets `WSL_DISTRIBUTION`, `WSL_IP`, and `WSL_TOOLS_MODULE_PATH` environment variables and action outputs.

### Caching

The action caches a `wsl --export` tar of the fully-provisioned distribution (Docker included) keyed on `setup-wsl-<distro>-distro<distroImageSha256[:16]>-setup<sha256(setup.ps1)[:16]>`. The distro image hash comes from Microsoft's [`DistributionInfo.json`](https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json), the same manifest `wsl --install` resolves against, so the cache refreshes automatically when a new distro image is published. This keeps the base image current for security updates. On a cache hit it imports the tar with `wsl --import`, skipping the download and the Docker install. The cache is subject to the 10 GB per-repository GitHub Actions limit (LRU + weekly eviction). Disable with `enable-cache: false`.

## What it does (Linux)

Nothing. Docker is already available on the runner. Sets `WSL_IP=127.0.0.1` and `WSL_DISTRIBUTION` to empty, so consuming actions can use the same interface unconditionally.

## Limitations

This action is designed for Particular's CI `setup-*-action` pattern. It is public, but external users should understand it is opinionated for this specific use case.

- **GitHub Actions hosted Windows runners only.** Requires WSL2 with nested virtualization. Will not work on self-hosted runners without WSL2, macOS, or other CI systems.
- **Default distribution is Ubuntu.** Distribution images are fetched from each distro's own infrastructure (Ubuntu from `releases.ubuntu.com`, Debian from `salsa.debian.org`), which is outside our control. Debian's WSL artifact on `salsa.debian.org` is currently serving inconsistent bytes and fails `Wsl/InstallDistro/VerifyChecksum/TRUST_E_BAD_DIGEST`, so Ubuntu (Canonical's release CDN) is the default and recommended; Debian remains selectable but may be unreliable until upstream is fixed ([microsoft/WSL#41279](https://github.com/microsoft/WSL/issues/41279)). The provisioned distribution is cached via `wsl --export`/`wsl --import` (keyed on the distro image hash from Microsoft's manifest and a hash of `setup.ps1`), so subsequent runs skip the download and the Docker install.
- **Installs Docker via the distribution's `docker.io` apt package**, not Docker's official repositories. May lag behind official Docker releases.
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