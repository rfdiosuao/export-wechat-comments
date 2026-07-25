import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

const root = resolve(import.meta.dirname, "..");
const skillRoot = resolve(root, "skill", "export-wechat-comments");
const skillPath = resolve(skillRoot, "SKILL.md");
const agentPath = resolve(skillRoot, "agents", "openai.yaml");
const failures = [];

function requireFile(path, label) {
  if (!existsSync(path)) failures.push(`missing ${label}: ${path}`);
}

function validateMarkdownLinks(path) {
  const markdown = readFileSync(path, "utf8");
  const links = [...markdown.matchAll(/\[[^\]]*\]\(([^)]+)\)/g)].map((match) => match[1]);
  for (const link of links) {
    if (/^(?:https?:|mailto:|#)/i.test(link)) continue;
    const filePart = link.split("#", 1)[0];
    if (!filePart) continue;
    const target = resolve(dirname(path), decodeURIComponent(filePart));
    if (!existsSync(target)) failures.push(`broken link in ${path}: ${link}`);
  }
}

requireFile(skillPath, "SKILL.md");
requireFile(agentPath, "agents/openai.yaml");

const scripts = [
  "preflight.ps1",
  "install-dependencies.ps1",
  "start-capture.ps1",
  "export-comments.ps1",
  "cleanup-capture.ps1",
  "render-comments.mjs",
];
for (const script of scripts) requireFile(resolve(skillRoot, "scripts", script), script);
requireFile(resolve(skillRoot, "references", "reproduction.md"), "reproduction reference");

const skill = readFileSync(skillPath, "utf8");
const frontmatter = skill.match(/^---\r?\n([\s\S]*?)\r?\n---/);
if (!frontmatter) {
  failures.push("SKILL.md has no YAML frontmatter");
} else {
  const name = frontmatter[1].match(/^name:\s*(.+)$/m)?.[1]?.trim();
  const description = frontmatter[1].match(/^description:\s*(.+)$/m)?.[1]?.trim();
  if (name !== "export-wechat-comments") failures.push(`unexpected skill name: ${name}`);
  if (!description || description.includes("TODO")) failures.push("skill description is missing");
}
if (/\bTODO\b/.test(skill)) failures.push("SKILL.md still contains TODO markers");
if (!skill.includes("references/reproduction.md")) failures.push("SKILL.md does not route to reproduction.md");
for (const script of scripts) {
  if (!skill.includes(script) && script !== "render-comments.mjs" && script !== "install-dependencies.ps1") {
    failures.push(`SKILL.md does not mention ${script}`);
  }
}

const agent = readFileSync(agentPath, "utf8");
if (!agent.includes("$export-wechat-comments")) failures.push("default prompt does not mention the skill");

validateMarkdownLinks(resolve(root, "README.md"));
validateMarkdownLinks(skillPath);
validateMarkdownLinks(resolve(skillRoot, "references", "reproduction.md"));

const repositoryText = [
  readFileSync(resolve(root, "README.md"), "utf8"),
  skill,
  readFileSync(resolve(skillRoot, "references", "reproduction.md"), "utf8"),
  ...scripts.map((script) => readFileSync(resolve(skillRoot, "scripts", script), "utf8")),
].join("\n");
const forbidden = [
  /gho_[A-Za-z0-9]{20,}/,
  /pass_ticket=[A-Za-z0-9_-]{8,}/,
  /appmsg_token=[A-Za-z0-9_-]{8,}/,
  /set_cookie\s*[=:]\s*["'][^"']+["']/i,
];
for (const pattern of forbidden) {
  if (pattern.test(repositoryText)) failures.push(`credential-like value matched ${pattern}`);
}

if (failures.length > 0) {
  process.stderr.write(`${failures.join("\n")}\n`);
  process.exit(1);
}
process.stdout.write("skill package validation passed\n");
