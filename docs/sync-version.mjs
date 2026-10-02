import { readFileSync, writeFileSync } from 'node:fs';

const pkg = JSON.parse(readFileSync(new URL('./package.json', import.meta.url), 'utf-8'));
const lockPath = new URL('./package-lock.json', import.meta.url);
const lock = JSON.parse(readFileSync(lockPath, 'utf-8'));

if (lock.version !== pkg.version || lock.packages?.['']?.version !== pkg.version) {
  lock.version = pkg.version;
  if (lock.packages?.['']) lock.packages[''].version = pkg.version;
  writeFileSync(lockPath, JSON.stringify(lock, null, 2) + '\n');
  console.log(`[sync-version] package-lock.json -> ${pkg.version}`);
}
