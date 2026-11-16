'use strict';
const path = require('node:path');
const os = require('node:os');

function dataDirectory(env = process.env) {
  const directory = env.CODEX_MONITOR_DATA || path.join(env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'CodexUsageMonitor');
  if (!path.isAbsolute(directory)) throw new Error('CODEX_MONITOR_DATA must be an absolute directory path.');
  return path.resolve(directory);
}
function launchOptions(command, env = process.env) {
  const source = path.join(__dirname, '../src');
  const powershell = path.join(env.SystemRoot || env.WINDIR || 'C:\\Windows', 'System32/WindowsPowerShell/v1.0/powershell.exe');
  const args = ['-NoLogo', '-NoProfile', '-STA', '-File', path.join(source, command === 'demo' ? 'launch-demo.ps1' : 'launch.ps1')];
  if (['mini', 'main', 'tray'].includes(command)) args.push(`-${command}`);
  return { executable: powershell, args, options: { cwd: source, windowsHide: true, stdio: 'inherit', env: { ...env, CODEX_MONITOR_DATA: dataDirectory(env) } } };
}
module.exports = { dataDirectory, launchOptions };
