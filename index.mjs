import * as path from 'node:path';
import * as url from 'node:url';
import * as core from '@actions/core';
import * as exec from '@actions/exec';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));

const setupPs1 = path.resolve(__dirname, '../setup.ps1');

const distribution = core.getInput('distribution') || 'Debian';
const memory = core.getInput('memory') || '4GB';

async function run() {
    try {
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