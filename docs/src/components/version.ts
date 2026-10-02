// Единый источник версии для всей вики: поле "version" в docs/package.json.
// Меняется там — обновляется на лендинге и во всех страницах установки.
// JSON-импорт: Vite вшивает содержимое файла в сборку, поэтому путь
// работает одинаково в dev и в готовом dist (в отличие от чтения с диска).
import pkg from '../../package.json';

/** «3.7.0» — без префикса, как в меню скрипта */
export const APP_VERSION = String((pkg as { version?: string }).version ?? '0.0.0').replace(/^v/, '');
/** «v3.7.0» — с префиксом, для бейджа на лендинге */
export const APP_VERSION_V = `v${APP_VERSION}`;
