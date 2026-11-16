#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const { spawn, spawnSync } = require('node:child_process');
const { version } = require('../package.json');
const { assertPlatform, ensureRuntime, matchesRuntime, runtimePath, spec } = require('../lib/runtime.cjs');
const { dataDirectory, launchOptions } = require('../lib/installation.cjs');

async function main() {
  const argv = process.argv.slice(2);
  const command = (argv[0] || 'start').replace(/^--/, '');
  if (argv.length > 1) throw new Error('Use one command at a time. Run codex-usage-monitor help.');
  if (['help', '-h'].includes(command)) {
    console.log(`Codex Usage Monitor ${version}\n\nUsage: codex-usage-monitor [command]\n\n  start            Restore the last view (default)\n  mini | main      Open the mini window or main window\n  tray             Start in the system tray\n  demo             Show simulated session animations\n  doctor           Check runtime and local Codex discovery\n  data-path        Print the persistent data directory\n  install-runtime  Verify or download the pinned Node.js runtime\n  version          Print the version\n\nRequires Windows x64. Data: %LOCALAPPDATA%\\CodexUsageMonitor\nOverride data with CODEX_MONITOR_DATA; override Codex discovery with CODEX_HOME.`);
    return;
  }
  if (['version', '-v'].includes(command)) { console.log(version); return; }
  assertPlatform();
  if (command === 'data-path') { console.log(dataDirectory()); return; }
  if (command === 'doctor') {
    const valid = await matchesRuntime();
    if (!valid) throw new Error('Bundled runtime missing or invalid. Reinstall the complete release package.');
    const launch = launchOptions('doctor');
    const result = spawnSync(launch.executable, launch.args, { ...launch.options, encoding: 'utf8', timeout: 15000 });
    if (result.error || result.status !== 0) throw new Error(result.stderr?.trim() || result.error?.message || `Native check exited with code ${result.status}.`);
    console.log(JSON.stringify({ ...JSON.parse(result.stdout), sha256Valid: true }, null, 2));
    return;
  }
  if (!['start', 'mini', 'main', 'tray', 'demo', 'install-runtime'].includes(command)) throw new Error(`Unknown command: ${command}. Run codex-usage-monitor help.`);
  if (command === 'install-runtime') {
    await ensureRuntime({ onDownload: () => console.log(`Downloading verified Node.js ${spec.version} from nodejs.org...`) });
    console.log(`Node.js ${spec.version} runtime verified.`); return;
  }
  const launch = launchOptions(command);
  if (!fs.existsSync(launch.executable) || !fs.existsSync(runtimePath)) throw new Error('Install the complete GitHub Release package, or build the native app from source.');
  await new Promise((resolve, reject) => {
    const child = spawn(launch.executable, launch.args, launch.options);
    child.once('error', reject);
    child.once('spawn', () => { child.unref(); resolve(); });
  });
}
main().catch(error => { console.error(`Codex Usage Monitor: ${error.message}`); process.exitCode = 1; });
