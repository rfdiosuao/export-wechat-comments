import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const root = resolve(import.meta.dirname, "..");
const renderer = join(root, "skill", "export-wechat-comments", "scripts", "render-comments.mjs");
const fixture = join(root, "tests", "fixtures", "comments.json");
const temp = mkdtempSync(join(tmpdir(), "wechat-comments-render-"));
const output = join(temp, "comments.md");

try {
  const result = spawnSync(
    process.execPath,
    [renderer, fixture, output, "测试文章", "https://mp.weixin.qq.com/s/test", "示例公众号"],
    { encoding: "utf8" },
  );
  if (result.status !== 0) {
    throw new Error(result.stderr || `renderer exited with ${result.status}`);
  }
  const markdown = readFileSync(output, "utf8");
  const assertions = [
    [markdown.includes("公开精选留言：2"), "selected comment count"],
    [markdown.includes("可见回复：2/3"), "reply count difference"],
    [markdown.includes("示例公众号（作者）"), "author label"],
    [markdown.includes("接口未返回正文"), "missing reply explanation"],
    [!markdown.includes("identity_name"), "no internal identity field"],
  ];
  const failed = assertions.filter(([ok]) => !ok).map(([, name]) => name);
  if (failed.length) throw new Error(`failed assertions: ${failed.join(", ")}`);
  process.stdout.write("render test passed\n");
} finally {
  rmSync(temp, { recursive: true, force: true });
}
