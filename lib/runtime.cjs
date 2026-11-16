'use strict';
const fs = require('node:fs');
const fsp = fs.promises;
const path = require('node:path');
const https = require('node:https');
const crypto = require('node:crypto');
const { pipeline } = require('node:stream/promises');
const spec = require('../runtime.json');
const packaged = path.join(__dirname, '../native');
const runtimePath = path.join(__dirname, fs.existsSync(packaged) ? '../native/runtime/node.exe' : '../src/runtime/node.exe');

function assertPlatform(platform = process.platform, arch = process.arch) {
  if (platform !== spec.platform || arch !== spec.arch) throw new Error('Codex Usage Monitor requires Windows x64. The WPF interface is not available on macOS, Linux or ARM64.');
}
async function fileHash(file) {
  const hash = crypto.createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) hash.update(chunk);
  return hash.digest('hex');
}
async function matchesRuntime(file = runtimePath, expected = spec.sha256) {
  try { return (await fileHash(file)) === expected.toLowerCase(); }
  catch (error) { if (error.code === 'ENOENT') return false; throw error; }
}
async function downloadRuntime(destination) {
  const response = await new Promise((resolve, reject) => {
    const request = https.get(spec.url, { timeout: 120000 }, resolve);
    request.on('error', reject);
    request.on('timeout', () => request.destroy(new Error('Node.js download timed out. Retry install-runtime.')));
  });
  if (response.statusCode !== 200) {
    response.resume();
    throw new Error(`Node.js download failed: HTTP ${response.statusCode}. Download the complete ZIP from GitHub Releases for offline use.`);
  }
  let bytes = 0;
  response.on('data', chunk => {
    bytes += chunk.length;
    if (bytes > 150 * 1024 * 1024) response.destroy(new Error('Runtime download exceeds the expected size limit.'));
  });
  await pipeline(response, fs.createWriteStream(destination, { flags: 'wx' }));
}
// Replace the target only after the complete download passes the pinned checksum.
async function ensureRuntime({ destination = runtimePath, download = downloadRuntime, expectedHash = spec.sha256, onDownload = () => {} } = {}) {
  if (await matchesRuntime(destination, expectedHash)) return { path: destination, downloaded: false };
  await fsp.mkdir(path.dirname(destination), { recursive: true });
  const temporary = `${destination}.${crypto.randomUUID()}.download`;
  try {
    onDownload();
    await download(temporary);
    if (!await matchesRuntime(temporary, expectedHash)) throw new Error('Runtime SHA-256 verification failed. The downloaded executable was not installed.');
    await fsp.rename(temporary, destination);
    return { path: destination, downloaded: true };
  } finally { await fsp.rm(temporary, { force: true }); }
}
module.exports = { assertPlatform, fileHash, matchesRuntime, ensureRuntime, runtimePath, spec };
