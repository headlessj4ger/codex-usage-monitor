'use strict';
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs/promises');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');
const root = require('./fixture-root.cjs');
const { ensureRuntime, assertPlatform } = require('../lib/runtime.cjs');
const { dataDirectory, launchOptions } = require('../lib/installation.cjs');
const payload = Buffer.from('synthetic verified runtime');
const hash = crypto.createHash('sha256').update(payload).digest('hex');

async function fixture(t) {
  const directory = await fs.mkdtemp(path.join(root, 'runtime-'));
  t.after(() => fs.rm(directory, { recursive: true, force: true }));
  return { directory, destination: path.join(directory, 'node.exe') };
}
test('runtime reuses a verified bundled executable without any network request', async t => {
  const { destination } = await fixture(t);
  await fs.writeFile(destination, payload);
  const result = await ensureRuntime({ destination, expectedHash: hash, download: () => { throw Error('unexpected download'); } });
  assert.equal(result.downloaded, false);
});
test('runtime download is checked before installation', async t => {
  const { destination, directory } = await fixture(t);
  const result = await ensureRuntime({ destination, expectedHash: hash, download: file => fs.writeFile(file, payload) });
  assert.equal(result.downloaded, true);
  assert.deepEqual(await fs.readFile(destination), payload);
  assert.deepEqual(await fs.readdir(directory), ['node.exe']);
});
test('failed checksum preserves the existing file and removes temporary data', async t => {
  const { destination, directory } = await fixture(t);
  await fs.writeFile(destination, 'previous runtime');
  await assert.rejects(ensureRuntime({ destination, expectedHash: hash, download: file => fs.writeFile(file, 'bad download') }), /SHA-256/);
  assert.equal(await fs.readFile(destination, 'utf8'), 'previous runtime');
  assert.deepEqual(await fs.readdir(directory), ['node.exe']);
});
test('interrupted download leaves no incomplete executable', async t => {
  const { destination, directory } = await fixture(t);
  await assert.rejects(ensureRuntime({ destination, expectedHash: hash, download: async file => { await fs.writeFile(file, 'partial'); throw Error('connection lost'); } }), /connection lost/);
  assert.deepEqual(await fs.readdir(directory), []);
});
test('unsupported platforms are rejected before download or launch', () => {
  assert.throws(() => assertPlatform('linux', 'x64'), /Windows x64/);
  assert.throws(() => assertPlatform('win32', 'arm64'), /Windows x64/);
});
test('npm state remains outside the installed package and custom Codex home is forwarded', () => {
  const env = { LOCALAPPDATA: path.join(root, 'user-data'), CODEX_HOME: path.join(root, 'codex-data') };
  const launch = launchOptions('mini', env);
  assert.equal(dataDirectory(env), path.join(env.LOCALAPPDATA, 'CodexUsageMonitor'));
  assert.equal(launch.options.env.CODEX_HOME, env.CODEX_HOME);
  assert.equal(launch.options.env.CODEX_MONITOR_DATA, dataDirectory(env));
  assert.equal(launch.args.at(-1), 'mini');
  assert.equal(path.basename(launch.executable), 'CodexUsageMonitor.exe');
  assert.equal(launch.options.detached, true);
  assert.throws(() => dataDirectory({ CODEX_MONITOR_DATA: 'relative-folder' }), /absolute/);
});
test('CLI version matches the application and invalid commands fail without launching', () => {
  const cli = path.resolve(__dirname, '../bin/codex-usage-monitor.cjs');
  const version = require('../src/version.json').version;
  assert.equal(require('../package.json').version, version);
  const result = spawnSync(process.execPath, [cli, '--version'], { encoding: 'utf8' });
  assert.equal(result.status, 0);
  assert.equal(result.stdout.trim(), version);
  const invalid = spawnSync(process.execPath, [cli, 'not-a-command'], { encoding: 'utf8' });
  assert.equal(invalid.status, 1);
  assert.match(invalid.stderr, /Unknown command/);
});
