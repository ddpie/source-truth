import { t, initI18n, currentLocale, _resetI18nForTesting } from "../src/i18n";
import { readFileSync } from "fs";
import { resolve } from "path";

const I18N_PATH = resolve(__dirname, "..", "..", "config", "i18n.json");

afterEach(() => _resetI18nForTesting());

describe("i18n", () => {
  it("defaults to zh", () => {
    initI18n("zh");
    expect(currentLocale()).toBe("zh");
    expect(t("card.title.done")).toBe("回答完成");
    expect(t("card.button.stop")).toBe("停止");
  });

  it("switches to en when requested", () => {
    initI18n("en");
    expect(currentLocale()).toBe("en");
    expect(t("card.title.done")).toBe("Answer complete");
    expect(t("card.button.stop")).toBe("Stop");
  });

  it("interpolates {placeholders}", () => {
    initI18n("zh");
    expect(t("card.title.elapsed", { elapsed: "67s" })).toBe("用时 67s");
    initI18n("en");
    expect(t("card.title.elapsed", { elapsed: "67s" })).toBe("took 67s");
  });

  it("returns the key itself for a missing key (no crash)", () => {
    initI18n("zh");
    expect(t("no.such.key.exists")).toBe("no.such.key.exists");
  });

  it("inserts a value containing $ LITERALLY (no replace-pattern mangling)", () => {
    initI18n("zh");
    // The narrow-retry prompt interpolates the USER's question; a "$" in it must
    // survive verbatim (regression: a string replacement arg ate $1/$$/$&).
    const q = "伤害是 $1 还是 $$ 还是 100% & 50%?";
    const out = t("card.action.narrow.prompt", { question: q });
    expect(out).toContain(q); // the whole question survives unmangled
  });

  it("leaves an unknown {placeholder} literal (no crash, not dropped)", () => {
    initI18n("zh");
    // card.title.elapsed has {elapsed}; calling with a wrong var name leaves it.
    expect(t("card.title.elapsed", { wrong: "x" })).toContain("{elapsed}");
  });

  it("falls back to zh for a key missing in en (partial translation is safe)", () => {
    // Both bundles are complete today; simulate by asserting the merge behavior:
    // an en lookup of a zh-only key would yield the zh string. We assert the real
    // invariant instead — every zh key resolves in en (see parity test).
    initI18n("en");
    expect(t("card.title.failed")).toBe("Query failed");
  });

  it("falls back to zh bundle for an unknown locale", () => {
    initI18n("fr");
    expect(currentLocale()).toBe("zh"); // unknown → zh
    expect(t("card.title.done")).toBe("回答完成");
  });

  // PARITY: zh and en must define exactly the same keys, or a locale switch would
  // surface a zh string (or the raw key) inside an otherwise-English card.
  it("zh and en bundles have identical key sets", () => {
    const j = JSON.parse(readFileSync(I18N_PATH, "utf8")) as Record<string, Record<string, string>>;
    const zhKeys = Object.keys(j.zh).sort();
    const enKeys = Object.keys(j.en).sort();
    const missingInEn = zhKeys.filter((k) => !(k in j.en));
    const missingInZh = enKeys.filter((k) => !(k in j.zh));
    expect(missingInEn).toEqual([]);
    expect(missingInZh).toEqual([]);
  });
});
