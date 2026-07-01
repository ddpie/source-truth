import eslint from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  eslint.configs.recommended,
  ...tseslint.configs.strict,
  {
    rules: {
      "@typescript-eslint/no-unused-vars": ["error", { argsIgnorePattern: "^_" }],
      // 全角空格（U+3000）在 CJK 注释里正常出现；正则/模板串里则是有意匹配
      // 中文排版的全角缩进（见 extract-followups.ts 的 marker 行锚定）。
      "no-irregular-whitespace": ["error", { skipComments: true, skipRegExps: true, skipTemplates: true, skipStrings: true }],
      // \x00 哨兵是 normalize-blocks.ts 的 fence 暂存记号（正文里不可能出现 NUL），有意为之。
      "no-control-regex": "off",
    },
  },
  {
    // 测试里对已断言存在的对象用 ! 是惯例（jest expect 已兜底）；require() 用于
    // 局部/延迟加载被测模块（jest CJS 环境），两者都不值得逐处改写。
    files: ["tests/**"],
    rules: {
      "@typescript-eslint/no-non-null-assertion": "off",
      "@typescript-eslint/no-require-imports": "off",
    },
  },
  { ignores: ["dist/", "node_modules/", "jest.config.ts"] },
);
