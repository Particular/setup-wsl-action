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

// Microsoft's authoritative list of installable WSL distributions. Each entry's
// Amd64Url.Sha256 changes exactly when a new distro image is published — the signal
// we want the cache to refresh on, so the base image stays current (security updates).
// This is the same manifest `wsl --install` resolves against.
const DISTRIBUTION_INFO_URL = 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json';

async function getDistroImageSha256(distribution) {
    const distroLower = distribution.toLowerCase();
    try {
        const res = await fetch(DISTRIBUTION_INFO_URL);
        if (!res.ok) {
            core.debug(`DistributionInfo.json fetch returned ${res.status}`);
            return 'unknown';
        }
        const json = await res.json();
        for (const family of Object.values(json.ModernDistributions || {})) {
            const entry = (Array.isArray(family) ? family : []).find(
                e => (e?.Name ?? '').toLowerCase() === distroLower
            );
            if (entry?.Amd64Url?.Sha256) {
                return entry.Amd64Url.Sha256;
            }
        }
        core.debug(`No '${distribution}' entry found in DistributionInfo.json`);
    } catch (err) {
        core.debug(`Could not fetch/parse DistributionInfo.json: ${err.message}`);
    }
    return 'unknown';
}

async function computeCacheKey(distribution) {
    const parts = ['setup-wsl', distribution.toLowerCase()];

    const distroSha = await getDistroImageSha256(distribution);
    parts.push(`distro-${distroSha.slice(0, 16)}`);

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
    const distribution = core.getInput('distribution') || 'Ubuntu';
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
