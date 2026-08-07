import * as path from 'node:path';
import * as url from 'node:url';
import * as core from '@actions/core';
import * as exec from '@actions/exec';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const setupPs1 = path.resolve(__dirname, '../setup.ps1');

const supportedDistros = ['ubuntu', 'debian'];

async function run() {
    const distribution = core.getInput('distribution') || 'Debian';
    const memory = core.getInput('memory') || '4GB';

    try {
        if (!supportedDistros.includes(distribution.toLowerCase())) {
            core.setFailed(`Unsupported distribution: ${distribution}. Supported options are: ${supportedDistros.join(', ')}`);
            return;
        }

        console.log('Running setup-wsl-action');
        console.log(`distribution = ${distribution}`);
        console.log(`memory = ${memory}`);

        await exec.exec('pwsh', [
            '-File', setupPs1,
            '-Distribution', distribution,
            '-Memory', memory
        ]);
    } catch (err) {
        core.setFailed(err);
        console.log(err);
    }
}

run();