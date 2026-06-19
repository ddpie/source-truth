import { normalizeBlocks } from "../src/normalize-blocks";

describe("normalizeBlocks — repair jammed block markers", () => {
  it("breaks an ATX heading jammed mid-prose onto its own line (real observed input)", () => {
    const input = "具体来说：### 魅力属性——有影响";
    const out = normalizeBlocks(input);
    expect(out).toContain("\n\n### 魅力属性");
    expect(out).not.toMatch(/：### /); // no longer jammed
  });

  it("breaks an HR jammed after a colon (observed: '分两大类：---###')", () => {
    const out = normalizeBlocks("怪物分两大类：---### 一、普通怪物");
    expect(out).toMatch(/两大类：\n\n-{3,}\n\n/);
    expect(out).toContain("### 一、普通怪物");
  });

  it("does NOT treat a ratio/range colon+dash as an HR (3:1-5:1)", () => {
    expect(normalizeBlocks("比例是 3:1-5:1 之间")).toBe("比例是 3:1-5:1 之间");
  });

  it("breaks an inline horizontal rule jammed after a sentence end", () => {
    const input = "值得注意。---### 礼仪（Etiquette）";
    const out = normalizeBlocks(input);
    expect(out).toMatch(/值得注意。\n\n-{3,}\n\n/);
    expect(out).toContain("### 礼仪");
  });

  it("breaks the real '…信息。---怪物…---## 一、' chain", () => {
    const input = "怪物分两种。---怪物的生命值不同。---## 一、野兽类型";
    const out = normalizeBlocks(input);
    expect(out).not.toMatch(/。---/); // no jammed HR remains
    expect(out).toContain("\n\n## 一、野兽类型");
  });
});

describe("normalizeBlocks — must NOT touch well-formed / protected content", () => {
  it("leaves a well-formed heading (already line-leading) untouched", () => {
    const input = "正文。\n\n### 标题\n内容";
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("never breaks a tight markdown TABLE separator row (|---|---|)", () => {
    const input = "| 档位 | 提升 |\n|---|---|\n| A | +25% |";
    expect(normalizeBlocks(input)).toBe(input);
  });

  // REGRESSION (observed live): a heading jammed onto a table's LAST row
  // ("| 1 | 2 |## 三、…") was skipped because the line contains a pipe → the ## stayed
  // jammed. A heading is never a table cell, so it must split out even on a table line.
  it("splits a heading jammed onto a table row's trailing pipe", () => {
    const out = normalizeBlocks("| 状态 | 速度 |\n| 行走 | 1.0 |## 三、外部加成");
    expect(out).toMatch(/\|\n\n## 三、外部加成/); // heading split onto its own line
    expect(out).not.toContain("|## 三"); // no longer jammed on the pipe
  });

  it("never breaks a SPACE-PADDED table separator row (| --- | --- |)", () => {
    const input = "结果：\n| 名称 | 值 |\n| --- | --- |\n| A | 1 |";
    // Every line here is a table line or prose with no jammed marker → untouched.
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("does NOT shred a `>` comparison or shell redirect in prose", () => {
    expect(normalizeBlocks("当血量 > 50% 时进入狂暴，伤害 > 基础值。")).toBe("当血量 > 50% 时进入狂暴，伤害 > 基础值。");
    expect(normalizeBlocks("启动用 java -jar app.jar > log.txt 2>&1。")).toBe("启动用 java -jar app.jar > log.txt 2>&1。");
  });

  it("does NOT break state-machine / lambda arrows (-->, ->, =>)", () => {
    expect(normalizeBlocks("状态：Idle --> Attack --> Cooldown")).toBe("状态：Idle --> Attack --> Cooldown");
    expect(normalizeBlocks("回调写成 () -> doAttack()")).toBe("回调写成 () -> doAttack()");
  });

  it("does not touch a `#` that is not a heading (C#, #3, #tag)", () => {
    const input = "这个值在 C# 里是 int，编号 #3 的字段，话题 #战斗。";
    expect(normalizeBlocks(input)).toBe(input);
  });

  it("does not break a dash range, and only splits an HR after a SENTENCE end", () => {
    // A range / comma-adjacent dash is NOT a divider → untouched.
    expect(normalizeBlocks("范围是 1-10 级，权重 28%。")).toBe("范围是 1-10 级，权重 28%。");
    expect(normalizeBlocks("说明：值在 1-10 级间，---暂不计。")).toBe("说明：值在 1-10 级间，---暂不计。");
    // But a rule right after 。/！/？ IS the observed jam shape → split out.
    expect(normalizeBlocks("第一部分讲完了。---第二部分")).toMatch(/了。\n\n---\n\n第二部分/);
  });

  it("leaves --- and ### inside a fenced code block literal", () => {
    const input = "看代码：\n```\nint x; ### not a heading\n--- not a rule\n```\n继续";
    const out = normalizeBlocks(input);
    expect(out).toContain("int x; ### not a heading\n--- not a rule");
  });

  it("protects an UNCLOSED trailing fence (streaming partial)", () => {
    const input = "看代码：\n```python\nx = 1 ### c\n值。--- 分隔";
    const out = normalizeBlocks(input);
    // The in-fence ### and --- must stay literal (no \n\n promotion inside).
    expect(out).toContain("x = 1 ### c");
    expect(out).toContain("值。--- 分隔");
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
