import assert from 'node:assert/strict';
import * as fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { randomBytes } from 'node:crypto';
import { encryptPackage, decryptPackage } from './notary-package.mjs';

// Synthetic bytes and a disposable password only. Never opens signing credentials.
const root = await fs.mkdtemp(path.join(os.tmpdir(), 'analiz-notary-crypto-test-'));
const file = name => path.join(root, name);
const password = 'synthetic-test-only-' + randomBytes(32).toString('base64');
const metadata = { schemaVersion: 1, submissionId: '11111111-2222-4333-8444-555555555555',
  architecture: 'arm64', sourceCommit: '1'.repeat(40), teamId: 'TESTTEAM01' };
const source = Buffer.concat([Buffer.from('PK\x03\x04'), randomBytes(1024 * 1024)]);
const noFile = async name => { await assert.rejects(fs.stat(file(name)), { code: 'ENOENT' }); };
let passed = 0;
try {
  await fs.writeFile(file('synthetic.zip'), source, { flag: 'wx' });
  await fs.writeFile(file('input.json'), JSON.stringify(metadata), { flag: 'wx' });
  const encryptedMetadata = await encryptPackage(file('synthetic.zip'), file('pending.json'), file('input.json'), password);
  const recoveredMetadata = await decryptPackage(file('pending.json'), file('recovered.zip'), file('recovered.json'), password);
  assert.deepEqual(await fs.readFile(file('recovered.zip')), source);
  assert.deepEqual(encryptedMetadata, recoveredMetadata);
  assert.deepEqual(JSON.parse(await fs.readFile(file('recovered.json'), 'utf8')), recoveredMetadata);
  assert(!String(await fs.readFile(file('pending.json'))).includes(password));
  console.log('PASS authenticated package and metadata roundtrip'); passed++;

  await assert.rejects(decryptPackage(file('pending.json'), file('wrong.zip'), file('wrong.json'), password + '-wrong'), /authentication failed/);
  await noFile('wrong.zip'); await noFile('wrong.json');
  console.log('PASS wrong password produces no plaintext'); passed++;

  const changedMetadata = JSON.parse(await fs.readFile(file('pending.json'), 'utf8'));
  changedMetadata.metadata.architecture = 'x86_64';
  await fs.writeFile(file('metadata-tampered.json'), JSON.stringify(changedMetadata));
  await assert.rejects(decryptPackage(file('metadata-tampered.json'), file('tampered.zip'), file('tampered-result.json'), password), /authentication failed/);
  await noFile('tampered.zip'); await noFile('tampered-result.json');
  const changedCiphertext = JSON.parse(await fs.readFile(file('pending.json'), 'utf8'));
  const damaged = Buffer.from(changedCiphertext.ciphertext, 'base64'); damaged[10] ^= 1;
  changedCiphertext.ciphertext = damaged.toString('base64');
  await fs.writeFile(file('cipher-tampered.json'), JSON.stringify(changedCiphertext));
  await assert.rejects(decryptPackage(file('cipher-tampered.json'), file('cipher.zip'), file('cipher-result.json'), password), /authentication failed/);
  await noFile('cipher.zip'); await noFile('cipher-result.json');
  console.log('PASS modified metadata and ciphertext produce no plaintext'); passed++;

  const originalEnvelope = await fs.readFile(file('pending.json'));
  await assert.rejects(encryptPackage(file('synthetic.zip'), file('pending.json'), file('input.json'), password), { code: 'EEXIST' });
  assert.deepEqual(await fs.readFile(file('pending.json')), originalEnvelope);
  await assert.rejects(decryptPackage(file('pending.json'), file('recovered.zip'), file('other.json'), password), { code: 'EEXIST' });
  assert.deepEqual(await fs.readFile(file('recovered.zip')), source); await noFile('other.json');
  await assert.rejects(decryptPackage(file('pending.json'), file('new.zip'), file('recovered.json'), password), { code: 'EEXIST' });
  await noFile('new.zip');
  console.log('PASS existing outputs preserved and partial reservation cleaned'); passed++;

  const badHash = { ...metadata, archiveSha256: '0'.repeat(64) };
  await fs.writeFile(file('bad-hash.json'), JSON.stringify(badHash));
  await assert.rejects(encryptPackage(file('synthetic.zip'), file('bad-envelope.json'), file('bad-hash.json'), password), /hash does not match/);
  await noFile('bad-envelope.json');
  assert.deepEqual(await fs.readFile(file('synthetic.zip')), source);
  console.log('PASS source hash checked and source bytes preserved'); passed++;

  const oversized = await fs.open(file('large.zip'), 'wx');
  await oversized.truncate(64 * 1024 * 1024 + 1); await oversized.close();
  await assert.rejects(encryptPackage(file('large.zip'), file('large-envelope.json'), file('input.json'), password), /size limit/);
  await noFile('large-envelope.json');
  console.log('PASS archive size bound enforced'); passed++;
  console.log(`PASS ${passed} pending-package scenarios`);
} finally {
  source.fill(0);
  const resolved = path.resolve(root);
  assert.equal(path.dirname(resolved), path.resolve(os.tmpdir()));
  assert(path.basename(resolved).startsWith('analiz-notary-crypto-test-'));
  // Only this mkdtemp-created, verified synthetic test directory is removed.
  await fs.rm(resolved, { recursive: true, force: true });
}
