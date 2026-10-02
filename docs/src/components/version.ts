// Единый источник версии для всей вики: поле "version" в docs/package.json.
// Меняется там — обновляется на лендинге и во всех страницах установки.
// (в dev-сервере после смены версии троньте этот файл или перезапустите npm run dev)
import { readFileSync } from 'node:fs';

const pkg = JSON.parse(
  readFileSync(new URL('../../package.json', import.meta.url), 'utf-8'),
) as { version?: string };

/** «3.7.0» — без префикса, как в меню скрипта */
export const APP_VERSION = String(pkg.version ?? '0.0.0').replace(/^v/, '');
/** «v3.7.0» — с префиксом, для бейджа на лендинге */
export const APP_VERSION_V = `v${APP_VERSION}`;
