import * as path from 'node:path';
import * as url from 'node:url';
import * as os from 'node:os';
import * as fs from 'node:fs';
import * as crypto from 'node:crypto';
import * as core from '@actions/core';
import * as exec from '@actions/exec';
import * as cache from '@actions/cache';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const setupPs1 = path.resolve(__dirname, '../setup.ps1');

const supportedDistros = ['ubuntu', 'debian'];

async function computeCacheKey(distribution) {
    const parts = ['setup-wsl', distribution.toLowerCase()];

    let wslVersion = 'unknown';
    try {
        const out = await exec.getExecOutput('wsl.exe', ['--version'], { silent: true });
        const line = out.stdout.split(/\r?\n/).find(l => /version/i.test(l));
        if (line) {
            wslVersion = line.split(':')[1]?.trim() || wslVersion;
        }
    } catch (err) {
        core.debug(`Could not determine WSL version: ${err.message}`);
    }
    parts.push(`wsl-${wslVersion}`);

    try {
        const hash = crypto.createHash('sha256').update(fs.readFileSync(setupPs1)).digest('hex').slice(0, 16);
        parts.push(`setup-${hash}`);
    } catch (err) {
        core.debug(`Could not hash setup.ps1: ${err.message}`);
        parts.push('setup-unknown');
    }

    return parts.join('-');
}

async function run() {
    const distribution = core.getInput('distribution') || 'Debian';
    const memory = core.getInput('memory') || '4GB';
    const enableCache = (core.getInput('enable-cache') || 'true').toLowerCase() !== 'false';
    const runnerOs = process.env.RUNNER_OS || '';

    try {
        if (!supportedDistros.includes(distribution.toLowerCase())) {
            core.setFailed(`Unsupported distribution: ${distribution}. Supported options are: ${supportedDistros.join(', ')}`);
            return;
        }

        core.info('Running setup-wsl-action');
        core.info(`distribution = ${distribution}`);
        core.info(`memory = ${memory}`);

        let importFromCache = null;
        let exportToCache = null;
        let cacheHit = false;
        let cacheKey = null;

        const cacheEnabled = enableCache && runnerOs === 'Windows';
        if (cacheEnabled) {
            cacheKey = await computeCacheKey(distribution);
            core.info(`WSL cache key: ${cacheKey}`);

            const cacheDir = path.join(process.env.RUNNER_TEMP || os.tmpdir(), 'setup-wsl-cache');
            const tarPath = path.join(cacheDir, `${distribution.toLowerCase()}.tar`);
            fs.mkdirSync(cacheDir, { recursive: true });

            try {
                const restoredKey = await cache.restoreCache([tarPath], cacheKey);
                if (restoredKey) {
                    cacheHit = true;
                    importFromCache = tarPath;
                    core.info(`WSL distro restored from cache key: ${restoredKey}`);
                } else {
                    exportToCache = tarPath;
                    core.info('WSL distro cache miss — provisioning fresh and exporting');
                }
            } catch (err) {
                core.warning(`Cache restore failed, continuing without cache: ${err.message}`);
                exportToCache = tarPath;
            }
        }

        core.setOutput('cache-hit', cacheHit ? 'true' : 'false');

        const pwshArgs = ['-File', setupPs1, '-Distribution', distribution, '-Memory', memory];
        if (importFromCache) {
            pwshArgs.push('-ImportFromCache', importFromCache);
        }
        if (exportToCache) {
            pwshArgs.push('-ExportToCache', exportToCache);
        }

        // On a cache miss, remove any partial tar left by a failed restore so we export fresh.
        if (exportToCache) {
            fs.rmSync(exportToCache, { force: true });
        }

        await exec.exec('pwsh', pwshArgs);

        if (exportToCache && fs.existsSync(exportToCache)) {
            try {
                const cacheId = await cache.saveCache([exportToCache], cacheKey);
                core.info(`WSL distro cache saved (id: ${cacheId})`);
            } catch (err) {
                // A parallel job may have saved the same key already; benign.
                core.warning(`Cache save skipped: ${err.message}`);
            }
        }
    } catch (err) {
        core.setFailed(err);
        core.info(err);
    }
}

run();
