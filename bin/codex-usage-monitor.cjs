#!/usr/bin/env node
'use strict';
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
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
    const home = path.resolve(process.env.CODEX_HOME || path.join(os.homedir(), '.codex'));
    const launch = launchOptions('start');
    const runtimeCheck = valid ? spawnSync(runtimePath, ['--no-warnings', path.join(__dirname, '../src/runtime-check.cjs')], { windowsHide: true, encoding: 'utf8', timeout: 10000 }) : null;
    const ready = valid && runtimeCheck.status === 0 && fs.existsSync(launch.executable);
    console.log(JSON.stringify({ version, platform: `${process.platform}-${process.arch}`, ready, runtime: { version: spec.version, sha256Valid: valid, sqliteReady: runtimeCheck?.status === 0 }, powershell: fs.existsSync(launch.executable), codexHome: home, codexFound: fs.existsSync(home), dataDirectory: dataDirectory() }, null, 2));
    if (!ready) process.exitCode = 1;
    return;
  }
  if (!['start', 'mini', 'main', 'tray', 'demo', 'install-runtime'].includes(command)) throw new Error(`Unknown command: ${command}. Run codex-usage-monitor help.`);
  await ensureRuntime({ onDownload: () => console.log(`Downloading verified Node.js ${spec.version} from nodejs.org...`) });
  if (command === 'install-runtime') { console.log(`Node.js ${spec.version} runtime verified.`); return; }
  const launch = launchOptions(command);
  await new Promise((resolve, reject) => {
    const child = spawn(launch.executable, launch.args, launch.options);
    child.once('error', reject);
    child.once('exit', (code, signal) => code === 0 ? resolve() : reject(new Error(`Launcher exited ${signal || code}. Check startup-error.log in ${dataDirectory()}.`)));
  });
}
main().catch(error => { console.error(`Codex Usage Monitor: ${error.message}`); process.exitCode = 1; });
