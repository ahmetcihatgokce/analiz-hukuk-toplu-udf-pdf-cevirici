import { appendFile } from 'node:fs/promises';
import { createPrivateKey, sign } from 'node:crypto';

const submissions = [
  { architecture: 'Apple Silicon', id: 'a9383fcb-e703-4980-bc7d-187ab9b94900' },
  { architecture: 'Intel', id: '46be0ee9-7a27-4e04-9a6d-d402ae502b96' },
];
for (const name of ['ASC_KEY_ID', 'ASC_ISSUER_ID', 'ASC_PRIVATE_KEY_P8']) {
  if (!process.env[name]) throw new Error('Missing configuration: ' + name);
}
const key = createPrivateKey(process.env.ASC_PRIVATE_KEY_P8);
delete process.env.ASC_PRIVATE_KEY_P8;
const now = Math.floor(Date.now() / 1000);
const header = Buffer.from(JSON.stringify({ alg: 'ES256', kid: process.env.ASC_KEY_ID, typ: 'JWT' })).toString('base64url');
const claims = Buffer.from(JSON.stringify({
  iss: process.env.ASC_ISSUER_ID, iat: now, exp: now + 300, aud: 'appstoreconnect-v1',
})).toString('base64url');
const input = header + '.' + claims;
const token = input + '.' + sign('sha256', Buffer.from(input), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
const statuses = await Promise.all(submissions.map(async submission => {
  const response = await fetch('https://appstoreconnect.apple.com/notary/v2/submissions/' + submission.id, {
    headers: { Authorization: 'Bearer ' + token }, signal: AbortSignal.timeout(30000),
  });
  if (!response.ok) throw new Error('Apple status HTTP ' + response.status);
  const body = await response.json();
  if (body.data?.id !== submission.id) throw new Error('Unexpected Apple submission identifier');
  const status = body.data.attributes?.status;
  if (!['Accepted', 'Invalid', 'Rejected', 'In Progress'].includes(status)) throw new Error('Unknown Apple submission status');
  return { ...submission, status };
}));
const checkedAt = new Date().toISOString();
for (const entry of statuses) console.log(entry.architecture + ': ' + entry.status + ' (' + entry.id + ')');
if (process.env.GITHUB_STEP_SUMMARY) {
  const lines = [
    '## Apple notarization status',
    '',
    'Checked at: ' + checkedAt,
    '',
    '| Mac package | Apple status | Submission ID |',
    '| --- | --- | --- |',
    ...statuses.map(s => '| ' + s.architecture + ' | **' + s.status + '** | ' + s.id + ' |'),
    '',
    '[Signing and submission run](https://github.com/ahmetcihatgokce/analiz-hukuk-toplu-udf-pdf-cevirici/actions/runs/44491930890).',
    '',
    'This is a read-only status check. It does not resubmit software or create a distribution package.',
  ];
  await appendFile(process.env.GITHUB_STEP_SUMMARY, lines.join('\n') + '\n');
}
