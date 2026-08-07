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
      distribution: Debian
      memory: 4GB
  - name: Run my service
    shell: pwsh
    run: |
      $distro = $Env:WSL_DISTRIBUTION
      $ip = $Env:WSL_IP
      wsl.exe --distribution $distro -- docker run --name myservice --detach --publish 1433:1433 myimage
      # Connection string uses $ip as the host on Windows
```

The action sets two environment variables for subsequent steps:

| Variable | Windows | Linux |
|---|---|---|
| `WSL_DISTRIBUTION` | The distribution name (e.g. `Debian`) | Empty string |
| `WSL_IP` | The WSL VM gateway IPv4 address | `127.0.0.1` |

Service actions can read these env vars to run Docker commands through WSL and construct connection strings with the correct host, without doing their own WSL provisioning. If the env vars are not set (e.g. the action wasn't called), service actions can fall back to provisioning WSL themselves — this is backwards-compatible with existing actions.

## Inputs

| Input | Required | Default | Description |
|---|:-:|:-:|---|
| `distribution` | No | `Debian` | The WSL distribution to install. Debian is recommended as the lightest officially-supported distribution. |
| `memory` | No | `4GB` | The memory limit for the WSL2 VM. Increase for memory-intensive services. |
| `enable-cache` | No | `true` | Whether to cache the provisioned WSL distribution across runs via `@actions/cache`. On hit, restores a `wsl --export` tar with `wsl --import`, skipping the distro download and Docker install. Defaults to `true`. |

The following environment variables can also override the inputs, for consistency with existing Particular setup actions:

| Variable | Default | Description |
|---|---|---|
| `WSL_DISTRIBUTION_OVERRIDE` | `Debian` | Override the distribution name. |
| `WSL_MEMORY_OVERRIDE` | `4GB` | Override the WSL2 VM memory limit. |

## Outputs

| Output | Description |
|---|---|
| `wsl-ip` | The WSL VM gateway IPv4 address. On Linux runners this is `127.0.0.1`. |
| `distribution` | The WSL distribution name that was provisioned. Empty on Linux runners. |
| `cache-hit` | `'true'` if the WSL distribution was restored from cache, `'false'` otherwise (including on Linux runners). |

## What it does (Windows)

1. Writes `%USERPROFILE%\.wslconfig` with `[wsl2]` + `memory=<N>GB` + `vmIdleTimeout=-1` — constrains the VM and prevents idle shutdown. Only writes if the file doesn't exist (local dev configs are preserved).
2. Enables WSL2 (`wsl --set-default-version 2`).
3. Installs the distribution if not already registered (`wsl --install Debian --no-launch`, retried on failure).
4. Installs Docker inside the distribution (`apt-get install docker.io`).
5. Starts the Docker daemon (systemd or SysV service).
6. Launches a D-Bus session bus to keep the WSL instance alive for the rest of the job (WSL terminates instances when no processes remain under its init).
7. Detects the WSL VM gateway IPv4 address via `hostname -I`.
8. Sets `WSL_DISTRIBUTION` and `WSL_IP` environment variables and action outputs.

### Caching

The action caches a `wsl --export` tar of the fully-provisioned distribution (Docker included) keyed on `setup-wsl-<distro>-wsl<wslVersion>-setup<sha256(setup.ps1)>`. On a cache hit it imports the tar with `wsl --import`, skipping the download and the Docker install. Subject to the 10 GB per-repository GitHub Actions cache limit (LRU + weekly eviction). Disable with `enable-cache: false`.

## What it does (Linux)

Nothing. Docker is already available on the runner. Sets `WSL_IP=127.0.0.1` and `WSL_DISTRIBUTION` to empty, so consuming actions can use the same interface unconditionally.

## Limitations

This action is designed for Particular's CI `setup-*-action` pattern. It is public, but external users should understand it is opinionated for this specific use case.

- **GitHub Actions hosted Windows runners only.** Requires WSL2 with nested virtualization. Will not work on self-hosted runners without WSL2, macOS, or other CI systems.
- **Installs Debian via `wsl --install` (no `--web-download`), retried with backoff.** Distribution downloads can fail transiently — notably `Wsl/InstallDistro/VerifyChecksum/TRUST_E_BAD_DIGEST` when Microsoft's CDN and distro manifest are briefly out of sync — so the install is retried a few times. The retry (not the delivery path) is what makes this reliable. The provisioned distribution is cached via `wsl --export`/`wsl --import` (keyed on the WSL version and a hash of `setup.ps1`), so subsequent runs skip the download and the Docker install.
- **Installs Docker via Debian's `docker.io` apt package**, not Docker's official repositories. May lag behind official Docker releases.
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

The `prepare` script runs `@vercel/ncc` to bundle `index.mjs` and its dependencies into `dist/index.mjs`. The committed `dist/` is what the runner executes — the source `index.mjs` is not used directly.

To test `setup.ps1` directly:

```bash
$Env:RUNNER_OS=Windows
.\setup.ps1 -Distribution Debian -Memory 4GB
```

Open the folder in Visual Studio Code with the DevContainer for a consistent development environment with Node.js, Docker-in-Docker, and PowerShell.

## License

MIT