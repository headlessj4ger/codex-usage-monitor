'use strict';
const path = require('node:path');
const os = require('node:os');

function dataDirectory(env = process.env) {
  const directory = env.CODEX_MONITOR_DATA || path.join(env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'CodexUsageMonitor');
  if (!path.isAbsolute(directory)) throw new Error('CODEX_MONITOR_DATA must be an absolute directory path.');
  return path.resolve(directory);
}
function launchOptions(command, env = process.env) {
  const native = path.join(__dirname, '../native');
  const diagnostic = command === 'doctor';
  return { executable: path.join(native, 'CodexUsageMonitor.exe'), args: [command],
    options: { cwd: native, windowsHide: diagnostic, detached: !diagnostic,
      stdio: diagnostic ? ['ignore', 'pipe', 'pipe'] : 'ignore',
      env: { ...env, CODEX_MONITOR_DATA: dataDirectory(env) } } };
}
module.exports = { dataDirectory, launchOptions };
