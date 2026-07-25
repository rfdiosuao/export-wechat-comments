---
name: export-wechat-comments
description: Export the public selected comments and visible replies from a WeChat Official Account article to a clean Markdown document on Windows. Use when a user asks to 抓取、爬取、导出、备份或整理微信公众号文章的评论区、留言和作者回复，especially when the article must be opened in an already logged-in WeChat desktop session and anonymous HTTP requests fail. Uses a temporary CurrentUser mitmproxy certificate and system proxy with mandatory rollback; never accesses unpublished comments.
---

# Export WeChat Comments

Export only the article's publicly selected comments and visible replies. Treat the article's total-message counter as informational: it can include unpublished or inaccessible messages.

## Required safety gate

Before capture, state the exact article and output path. Obtain explicit approval for both temporary actions unless the user's current request already clearly authorizes them:

1. Install one mitmproxy CA certificate in `CurrentUser\Root`.
2. Temporarily replace the current WinINET system proxy.

Record the old proxy and exact certificate thumbprint. Never print or quote `key`, `uin`, `pass_ticket`, `appmsg_token`, cookies, or the captured credential URL. Never commit raw response JSON, credentials, certificates, logs, avatars, `openid`, or `identity_name`.

Do not automate Windows certificate/security confirmation dialogs. If Windows asks for confirmation, hand control to the user.

## Workflow

Read [references/reproduction.md](references/reproduction.md) before installing dependencies, troubleshooting, or changing the workflow.

1. Check dependencies with `scripts/preflight.ps1`.
2. If dependencies are missing, explain the network and software changes, then run `scripts/install-dependencies.ps1` only after approval.
3. Run `scripts/start-capture.ps1`. Use ports that pass the preflight bind test; Windows excluded port ranges can make an apparently unused port fail with `EACCES`.
4. Open the target article inside the user's already logged-in WeChat desktop client.
   - Prefer clicking an existing article link.
   - Do not send the URL through chat, like, comment, follow, or reply without action-time confirmation.
   - If no existing link is available, ask the user to open the article manually.
5. Wait until `credentials.json` contains one target entry. Check only existence, entry count, and matching `biz`; do not display its contents.
6. Run `scripts/export-comments.ps1` with the capture state and safe public article URL.
7. Always run `scripts/cleanup-capture.ps1` in a `finally` path, including after failures or interruptions.
8. Verify that the original proxy is restored, the exact certificate is absent, capture ports are closed, and credentials/raw JSON are gone.

## Commands

Use paths appropriate to the machine:

```powershell
$skill = "C:\path\to\export-wechat-comments"
$deps = "C:\path\to\wechat-tools"
$session = Join-Path $env:TEMP "wechat-comment-capture"

& "$skill\scripts\preflight.ps1" `
  -WxdownPath "$deps\wxdown-service" `
  -CapturePort 65100 -WssPort 65102

& "$skill\scripts\start-capture.ps1" `
  -WxdownPath "$deps\wxdown-service" `
  -SessionDirectory $session `
  -CapturePort 65100 -WssPort 65102

& "$skill\scripts\export-comments.ps1" `
  -StatePath "$session\capture-state.json" `
  -ArticleUrl "https://mp.weixin.qq.com/s/ARTICLE_ID" `
  -OutputPath "C:\output\article-comments.md"

& "$skill\scripts\cleanup-capture.ps1" `
  -StatePath "$session\capture-state.json"
```

## Result reporting

Report separately:

- article total-message counter;
- public selected comments exported;
- visible replies exported;
- reply counts whose bodies were not returned.

Explain that missing public bodies are usually deleted or currently invisible. Never imply that the skill can retrieve author-unpublished comments.
