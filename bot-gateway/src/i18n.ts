/**
 * Tiny i18n for user-facing CardKit copy.
 *
 * All card chrome text (titles, buttons, panel headings, status lines, failure
 * messages) lives in config/i18n.json — NOT inline in code — so copy can be tuned
 * and translated without touching logic. Default locale is zh; set LOCALE=en (or
 * any configured locale) to switch. A missing key returns the key itself (visible,
 * not a crash) and logs once, so a typo is caught in testing rather than shipping a
 * blank label.
 *
 * NOT in scope here: the markers the AGENT emits in its answer text that the
 * gateway PARSES (供研发复核 / 你可能还想问 / 需要你确认). Those are the system.md
 * contract — translating them would break extraction. They stay in the prompt.
 */

import { readFileSync } from "fs";
import { resolve } from "path";

type Bundle = Record<string, string>;

let bundle: Bundle | null = null;
let activeLocale = "zh";
const warned = new Set<string>();

/** Load config/i18n.json and select the locale (LOCALE env, default zh). Idempotent;
 *  call once at startup, but lazy-loads on first t() too. Exposed for tests. */
export function initI18n(localeOverride?: string): void {
  const locale = localeOverride ?? process.env.LOCALE ?? "zh";
  // config/ is a sibling of bot-gateway/ at the repo root.
  const path = resolve(__dirname, "..", "..", "config", "i18n.json");
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(readFileSync(path, "utf8")) as Record<string, unknown>;
  } catch (e) {
    throw new Error(`i18n: cannot load ${path}: ${String(e)}`);
  }
  const locales = parsed as Record<string, Bundle>;
  const chosen = locales[locale] ?? locales["zh"];
  if (!chosen) throw new Error(`i18n: no 'zh' bundle in ${path}`);
  // Fall back to zh for any key missing in a non-zh locale (partial translation is
  // safe — you get Chinese for the untranslated key, never a blank).
  bundle = locale === "zh" ? chosen : { ...(locales["zh"] ?? {}), ...chosen };
  activeLocale = locales[locale] ? locale : "zh";
}

export function currentLocale(): string {
  if (bundle === null) initI18n();
  return activeLocale;
}

/**
 * Translate `key`, interpolating `{name}` placeholders from `vars`. Returns the
 * key itself (and warns once) if it's missing — visible in testing, never a crash.
 */
export function t(key: string, vars?: Record<string, string | number>): string {
  if (bundle === null) initI18n();
  let s = bundle![key];
  if (s === undefined) {
    if (!warned.has(key)) {
      warned.add(key);
      // eslint-disable-next-line no-console
      console.log(JSON.stringify({ event: "i18n_missing_key", key, locale: activeLocale }));
    }
    return key;
  }
  if (vars) {
    for (const [k, v] of Object.entries(vars)) {
      s = s.replace(new RegExp(`\\{${k}\\}`, "g"), String(v));
    }
  }
  return s;
}

/** Test helper: reset loaded state so a test can re-init with a different locale. */
export function _resetI18nForTesting(): void {
  bundle = null;
  activeLocale = "zh";
  warned.clear();
}
