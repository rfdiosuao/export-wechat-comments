# export-wechat-comments

一个面向 Codex/Agent 的 Windows Skill：复用已登录微信桌面端会话，抓取公众号文章公开精选留言和可见回复，并导出干净的 Markdown。

## 能做什么

- 自动处理顶级留言 `buffer` 分页；
- 补抓未内嵌的公开回复；
- 修复 Windows PowerShell 常见的中文 UTF-8 解码问题；
- 区分“文章留言总计数”和“公开精选留言数”；
- 只输出昵称、正文、时间、点赞和作者标记；
- 精确恢复原系统代理并清理临时证书、凭据和原始 JSON。

不能获取作者未公开的留言，也不会绕过微信登录或安全限制。

## 安装 Skill

```powershell
git clone https://github.com/rfdiosuao/export-wechat-comments.git
Copy-Item -Recurse -Force `
  '.\export-wechat-comments\skill\export-wechat-comments' `
  "$env:USERPROFILE\.codex\skills\export-wechat-comments"
```

重启 Codex 后使用：

```text
使用 $export-wechat-comments 抓取这篇公众号文章的公开留言并导出 Markdown：<URL>
```

## 快速开始

完整步骤、安全边界和排障说明见：[完整复现文档](skill/export-wechat-comments/references/reproduction.md)。

核心流程：

```powershell
$skill = Resolve-Path '.\skill\export-wechat-comments'
$deps = 'C:\wechat-tools'
$session = Join-Path $env:TEMP 'wechat-comment-capture'

& "$skill\scripts\install-dependencies.ps1" -Destination $deps -SkipExporter
& "$skill\scripts\preflight.ps1" -WxdownPath "$deps\wxdown-service"
& "$skill\scripts\start-capture.ps1" `
  -WxdownPath "$deps\wxdown-service" `
  -SessionDirectory $session

# 此时在已登录的微信桌面端打开目标文章。

& "$skill\scripts\export-comments.ps1" `
  -StatePath "$session\capture-state.json" `
  -ArticleUrl 'https://mp.weixin.qq.com/s/ARTICLE_ID' `
  -OutputPath 'C:\output\article-comments.md'

& "$skill\scripts\cleanup-capture.ps1" `
  -StatePath "$session\capture-state.json"
```

## 安全说明

此流程需要用户明确同意临时安装 CurrentUser 根证书和切换系统代理。不要把 `credentials.json`、Cookie、完整捕获 URL、原始 JSON、证书或日志提交到仓库。

如果 Windows 弹出“根证书存储”确认框，必须由用户亲自确认；Skill 不会自动点击安全界面。

## 上游

- [wechat-article/wechat-article-exporter](https://github.com/wechat-article/wechat-article-exporter)（MIT）
- [wechat-article/wxdown-service](https://github.com/wechat-article/wxdown-service)（上游当前未声明许可证，本仓库不包含其源代码）

## 许可证

本仓库自己的代码以 [MIT](LICENSE) 许可证发布。第三方依赖遵循各自许可证和服务条款。
