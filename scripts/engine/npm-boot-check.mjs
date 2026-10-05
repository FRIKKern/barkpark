// The App shape as an app meets it: @barkpark/engine and its platform package are
// installed from their npm tarballs, and one startBarkpark call with only a dataDir
// boots Barkpark. No release path, no BARKPARK_ENGINE_RELEASE.
//
// engine-release.yml copies this file into a scratch app that installed both
// tarballs and runs it there, so `@barkpark/engine` resolves from that app's
// node_modules. Exits 0 when /status.json answers with the returned token.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { startBarkpark, findPlatformRelease } from '@barkpark/engine';

if (process.env.BARKPARK_ENGINE_RELEASE) {
  console.error('BARKPARK_ENGINE_RELEASE is set; this check must find the engine through the platform package alone.');
  process.exit(2);
}
const found = findPlatformRelease();
if (!found || !found.includes(`${path.sep}node_modules${path.sep}`)) {
  console.error(`The platform package was not found in node_modules (got ${found}).`);
  process.exit(1);
}

const dataDir = fs.mkdtempSync(path.join(os.tmpdir(), 'barkpark-npm-boot-'));
const started = Date.now();
const barkpark = await startBarkpark({ dataDir });
try {
  const res = await fetch(`${barkpark.url}/status.json`, { headers: { authorization: `Bearer ${barkpark.token}` } });
  if (res.status !== 200) throw new Error(`/status.json answered ${res.status}`);
  const body = await res.json();
  // status.json carries the short commit; the engine folder records the full one.
  if (!body.commit || !barkpark.commit.startsWith(body.commit)) throw new Error(`/status.json reports commit ${body.commit}; the engine folder holds ${barkpark.commit}.`);
  console.log(JSON.stringify({ engineFolder: found, commit: body.commit, shape: body.shape, bootMs: Date.now() - started, components: body.components.map(c => `${c.name}:${c.status}`) }));
} finally {
  await barkpark.stop();
}
