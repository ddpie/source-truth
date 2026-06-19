import { normalizeBlocks } from "../src/normalize-blocks";

describe("normalizeBlocks — repair jammed block markers", () => {
  it("breaks an ATX heading jammed mid-prose onto its own line (real observed input)", () => {
    const input = "具体来说：### 魅力属性——有影响";
    const out = normalizeBlocks(input);
    expect(out).toContain("\n\n### 魅力属性");
    expect(out).not.toMatch(/：### /); // no longer jammed
  });

  it("breaks an inline horizontal rule jammed between sentences", () => {
    const input = "值得注意。---### 礼仪（Etiquette）";
    const out = normalizeBlocks(input);
    // The rule and the following heading each get their own line.
    expect(out).toMatch(/值得注意。\n\n-{3,}\n\n/);
    expect(out).toContain("### 礼仪");
  });

  it("breaks a blockquote marker jammed after prose", () => {
    const input = "一句话总结> 想要砍价只有商贩技能管用";
    const out = normalizeBlocks(input);
    expect(out).toContain("\n\n> 想要砍价");
  });
});

describe("normalizeBlocks — must NOT touch well-formed / protected content", () => {
  it("leaves a well-formed heading (already line-leading) untouched", () => {
    const input = "正文。\n\n### 标题\n内容";
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("never breaks a markdown TABLE separator row", () => {
    const input = "| 档位 | 提升 |\n|---|---|\n| A | +25% |";
    const out = normalizeBlocks(input);
    expect(out).toContain("|---|---|"); // table separator intact
    expect(out).not.toContain("\n\n---"); // not turned into an HR
  });

  it("does not touch a `#` that is not a heading (C#, #3)", () => {
    const input = "这个值在 C# 里是 int，编号 #3 的字段。";
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("leaves --- and ### inside a fenced code block literal", () => {
    const input = "看代码：\n```\nint x; ### not a heading\n--- not a rule\n```\n继续";
    const out = normalizeBlocks(input);
    expect(out).toContain("### not a heading");
    expect(out).toContain("--- not a rule");
    // The fence content must be byte-identical (no \n\n injected inside it).
    expect(out).toContain("int x; ### not a heading\n--- not a rule");
  });

  it("does not touch a single hyphen or a 1-2 char dash run", () => {
    const input = "1-10 级是 1.5 倍，权重约占 28%。";
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("leaves a line-leading HR untouched", () => {
    const input = "正文结论。\n\n---\n\n下一段。";
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("returns empty/short input unchanged", () => {
    expect(normalizeBlocks("")).toBe("");
    expect(normalizeBlocks("普通一句话答案。")).toBe("普通一句话答案。");
  });
});
