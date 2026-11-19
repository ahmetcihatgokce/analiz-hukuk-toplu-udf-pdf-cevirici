#!/usr/bin/env node
// Pending notarization storage only. No key, password or P12 is put in the envelope.
import { constants } from 'node:fs';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { createHash, createCipheriv, createDecipheriv, hkdfSync, randomBytes } from 'node:crypto';

const MAX_ZIP = 64 * 1024 * 1024;
const MAX_ENVELOPE = 96 * 1024 * 1024;
const CONTEXT = Buffer.from('AnalizHukuk Mac Notary Pending v1', 'utf8');
const FORMAT = 'AnalizHukukMacNotaryPending';
class PackageError extends Error {}
const fail = message => { throw new PackageError(message); };

async function readRegular(file, limit) {
  const before = await fs.lstat(file);
  if (!before.isFile() || before.isSymbolicLink() || before.size <= 0 || before.size > limit) {
    fail('Input must be a nonempty regular file within the size limit.');
  }
  const handle = await fs.open(file, constants.O_RDONLY | (constants.O_NOFOLLOW ?? 0));
  const chunks = [];
  try {
    const current = await handle.stat();
    if (!current.isFile() || current.dev !== before.dev || current.ino !== before.ino || current.size > limit) {
      fail('Input file changed before it could be opened.');
    }
    let length = 0;
    while (true) {
      const chunk = Buffer.alloc(65536);
      const { bytesRead } = await handle.read(chunk, 0, chunk.length, null);
      if (!bytesRead) { chunk.fill(0); break; }
      length += bytesRead;
      if (length > limit) { chunk.fill(0); fail('Input exceeds the size limit.'); }
      chunks.push(chunk.subarray(0, bytesRead));
    }
    if (!length) fail('Input is empty.');
    return Buffer.concat(chunks, length);
  } finally {
    for (const chunk of chunks) chunk.fill(0);
    await handle.close();
  }
}

function parseJSON(bytes) {
  try { return JSON.parse(bytes.toString('utf8')); }
  catch { fail('Invalid JSON input.'); }
}

function metadataProjection(input, computedHash) {
  if (!input || typeof input !== 'object' || Array.isArray(input) ||
      (input.schemaVersion !== undefined && input.schemaVersion !== 1)) fail('Invalid metadata schema.');
  const { submissionId, architecture, sourceCommit, teamId } = input;
  if (typeof submissionId !== 'string' || !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(submissionId)) fail('Invalid submission ID.');
  if (!['arm64', 'x86_64'].includes(architecture)) fail('Invalid architecture.');
  if (typeof sourceCommit !== 'string' || !/^[0-9a-f]{40}$/i.test(sourceCommit)) fail('Invalid source commit.');
  if (typeof teamId !== 'string' || !/^[A-Z0-9]{10}$/.test(teamId)) fail('Invalid team ID.');
  const hash = input.archiveSha256 ?? computedHash;
  if (typeof hash !== 'string' || !/^[0-9a-f]{64}$/i.test(hash)) fail('Invalid archive hash.');
  if (computedHash && hash.toLowerCase() !== computedHash) fail('Archive hash does not match.');
  // Fixed field order is the authenticated canonical projection.
  return { schemaVersion: 1, submissionId: submissionId.toLowerCase(), architecture,
    sourceCommit: sourceCommit.toLowerCase(), teamId, archiveSha256: hash.toLowerCase() };
}

function deriveKey(password, salt) {
  if (typeof password !== 'string' || !password.length || Buffer.byteLength(password) > 4096) {
    fail('MAC_CERTIFICATE_PASSWORD is required.');
  }
  const bytes = Buffer.from(password, 'utf8');
  try { return Buffer.from(hkdfSync('sha256', bytes, salt, CONTEXT, 32)); }
  finally { bytes.fill(0); }
}

function base64Bytes(value, expectedLength, maxLength = expectedLength) {
  if (typeof value !== 'string' || value.length > Math.ceil(maxLength / 3) * 4 || value.length % 4 !== 0) fail('Invalid envelope encoding.');
  const result = Buffer.from(value, 'base64');
  if (result.length > maxLength || (expectedLength !== undefined && result.length !== expectedLength) ||
      result.toString('base64') !== value) { result.fill(0); fail('Invalid envelope field size.'); }
  return result;
}

async function writeNewFiles(items) {
  const names = items.map(([name]) => path.resolve(name).toLowerCase());
  if (new Set(names).size !== names.length) fail('Output paths must be distinct.');
  const opened = [];
  let complete = false;
  try {
    // Reserve all outputs exclusively before writing any authenticated plaintext.
    for (const [name, bytes] of items) {
      const handle = await fs.open(name, 'wx', 0o600);
      opened.push({ name, bytes, handle, stat: await handle.stat() });
    }
    for (const item of opened) { await item.handle.writeFile(item.bytes); await item.handle.sync(); }
    complete = true;
  } finally {
    for (const item of opened) await item.handle.close();
    if (!complete) {
      for (const item of opened) {
        try {
          const current = await fs.lstat(item.name);
          if (current.isFile() && !current.isSymbolicLink() && current.dev === item.stat.dev && current.ino === item.stat.ino) await fs.unlink(item.name);
        } catch { /* Leave unrelated/replaced paths untouched. */ }
      }
    }
  }
}

export async function encryptPackage(zipPath, envelopePath, metadataPath, password = process.env.MAC_CERTIFICATE_PASSWORD) {
  let zip, metadataBytes, key, encrypted;
  try {
    zip = await readRegular(zipPath, MAX_ZIP);
    metadataBytes = await readRegular(metadataPath, 16384);
    const metadata = metadataProjection(parseJSON(metadataBytes), createHash('sha256').update(zip).digest('hex'));
    const salt = randomBytes(32), iv = randomBytes(12);
    key = deriveKey(password, salt);
    const cipher = createCipheriv('aes-256-gcm', key, iv);
    cipher.setAAD(Buffer.from(JSON.stringify(metadata), 'utf8'));
    encrypted = Buffer.concat([cipher.update(zip), cipher.final()]);
    const envelope = { format: FORMAT, version: 1, metadata, salt: salt.toString('base64'),
      iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64'), ciphertext: encrypted.toString('base64') };
    await writeNewFiles([[envelopePath, Buffer.from(JSON.stringify(envelope) + '\n', 'utf8')]]);
    return metadata;
  } finally {
    for (const bytes of [zip, metadataBytes, key, encrypted]) bytes?.fill(0);
  }
}

export async function decryptPackage(envelopePath, zipPath, metadataPath, password = process.env.MAC_CERTIFICATE_PASSWORD) {
  let envelopeBytes, key, encrypted, plain;
  try {
    envelopeBytes = await readRegular(envelopePath, MAX_ENVELOPE);
    const envelope = parseJSON(envelopeBytes);
    if (!envelope || envelope.format !== FORMAT || envelope.version !== 1) fail('Unsupported envelope format.');
    const metadata = metadataProjection(envelope.metadata);
    const salt = base64Bytes(envelope.salt, 32), iv = base64Bytes(envelope.iv, 12), tag = base64Bytes(envelope.tag, 16);
    encrypted = base64Bytes(envelope.ciphertext, undefined, MAX_ZIP);
    if (!encrypted.length) fail('Encrypted archive is empty.');
    key = deriveKey(password, salt);
    const decipher = createDecipheriv('aes-256-gcm', key, iv);
    decipher.setAAD(Buffer.from(JSON.stringify(metadata), 'utf8'));
    decipher.setAuthTag(tag);
    const chunks = [];
    try {
      chunks.push(decipher.update(encrypted));
      chunks.push(decipher.final());
      plain = Buffer.concat(chunks);
    } catch { fail('Pending package authentication failed.'); }
    finally { for (const chunk of chunks) chunk.fill(0); }
    if (createHash('sha256').update(plain).digest('hex') !== metadata.archiveSha256) fail('Decrypted archive hash does not match.');
    await writeNewFiles([[zipPath, plain], [metadataPath, Buffer.from(JSON.stringify(metadata, null, 2) + '\n', 'utf8')]]);
    return metadata;
  } finally {
    for (const bytes of [envelopeBytes, key, encrypted, plain]) bytes?.fill(0);
  }
}

async function main() {
  const [mode, ...args] = process.argv.slice(2);
  if (args.length !== 3 || !['encrypt', 'decrypt'].includes(mode)) fail('Usage: notary-package.mjs encrypt <zip> <envelope.json> <metadata.json> | decrypt <envelope.json> <zip> <metadata-output.json>');
  if (mode === 'encrypt') await encryptPackage(...args);
  else await decryptPackage(...args);
  console.log(mode === 'encrypt' ? 'Encrypted pending package created.' : 'Authenticated pending package recovered.');
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
  main().catch(error => {
    console.error(error instanceof PackageError ? error.message : 'Pending package operation failed. Check paths and existing output files.');
    process.exitCode = 1;
  });
}
