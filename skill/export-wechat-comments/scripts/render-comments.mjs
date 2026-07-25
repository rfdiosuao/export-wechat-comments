import { readFileSync, writeFileSync } from "node:fs";

const [, , inputPath, outputPath, titleArg, articleUrlArg, accountArg] = process.argv;
if (!inputPath || !outputPath) {
  throw new Error("Usage: node render-comments.mjs INPUT_JSON OUTPUT_MD [TITLE] [ARTICLE_URL] [ACCOUNT]");
}

const data = JSON.parse(readFileSync(inputPath, "utf8"));
const comments = Array.isArray(data.elected_comment) ? data.elected_comment : [];
const title = titleArg || "WeChat article";
const articleUrl = articleUrlArg || "";
const account = accountArg || "Unknown account";

function escapeInline(value) {
  return String(value ?? "")
    .replaceAll("\\", "\\\\")
    .replace(/([*_`[\]<>#])/g, "\\$1")
    .trim();
}

function formatTime(seconds) {
  if (!seconds) return "时间未知";
  return new Intl.DateTimeFormat("zh-CN", {
    timeZone: "Asia/Shanghai",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    hour12: false,
  }).format(new Date(Number(seconds) * 1000));
}

function quoteLines(value, prefix = "> ") {
  const text = String(value ?? "").trim() || "（空白内容）";
  return text.split(/\r?\n/).map((line) => `${prefix}${line || " "}`);
}

function replyKey(reply) {
  return [reply.reply_id, reply.create_time, reply.identity_name, reply.content].join("|");
}

let declaredReplies = 0;
let visibleReplies = 0;
for (const comment of comments) {
  const info = comment.reply_new ?? {};
  const replies = Array.isArray(info.reply_list) ? info.reply_list : [];
  declaredReplies += Number(info.reply_total_cnt ?? replies.length);
  visibleReplies += replies.length;
}
const missingReplies = Math.max(0, declaredReplies - visibleReplies);

const lines = [
  `# 《${escapeInline(title)}》公众号公开留言`,
  "",
];
if (articleUrl) lines.push(`- 原文：[${articleUrl}](${articleUrl})`);
lines.push(
  `- 公众号：${escapeInline(account)}`,
  `- 导出时间：${formatTime(Math.floor(Date.now() / 1000))}`,
  `- 文章留言总计数：${Number(data.total_count ?? 0)}（包含未公开精选或当前不可访问的留言）`,
  `- 公开精选留言：${comments.length}`,
  `- 可见回复：${visibleReplies}/${declaredReplies}`,
  "",
  "> 说明：本文档只整理文章页面公开展示的精选留言及可见回复，不包含作者未公开的留言。",
);
if (missingReplies > 0) {
  lines.push(`> 接口中另有 ${missingReplies} 条回复只保留计数、没有返回正文，通常表示回复已删除或当前不可见。`);
}

for (let index = 0; index < comments.length; index += 1) {
  const comment = comments[index];
  const nickname = escapeInline(comment.nick_name) || "匿名用户";
  const likes = Number(comment.like_num ?? 0);
  const topLabel = Number(comment.is_top ?? 0) === 1 ? " · 置顶" : "";
  lines.push(
    "",
    `## ${index + 1}. ${nickname}`,
    "",
    `- ${formatTime(comment.create_time)} · 赞 ${likes}${topLabel}`,
    "",
    ...quoteLines(comment.content),
  );

  const info = comment.reply_new ?? {};
  const rawReplies = Array.isArray(info.reply_list) ? info.reply_list : [];
  const seen = new Set();
  const replies = rawReplies.filter((reply) => {
    const key = replyKey(reply);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  const declared = Number(info.reply_total_cnt ?? replies.length);
  if (declared > 0 || replies.length > 0) {
    lines.push("", `### 回复（可见 ${replies.length}/${declared}）`);
    for (let replyIndex = 0; replyIndex < replies.length; replyIndex += 1) {
      const reply = replies[replyIndex];
      const authorLabel = Number(reply.identity_type ?? 0) === 1 || Number(reply.is_from ?? 0) === 2
        ? "（作者）"
        : "";
      const replyName = escapeInline(reply.nick_name) || "匿名用户";
      const replyLikes = Number(reply.reply_like_num ?? 0);
      lines.push(
        "",
        `${replyIndex + 1}. **${replyName}${authorLabel}** — ${formatTime(reply.create_time)} · 赞 ${replyLikes}`,
        ...quoteLines(reply.content, "   > "),
      );
    }
    if (declared > replies.length) {
      lines.push("", `> 注：另有 ${declared - replies.length} 条回复只有计数，接口未返回正文。`);
    }
  }
}

writeFileSync(outputPath, `${lines.join("\n")}\n`, "utf8");
