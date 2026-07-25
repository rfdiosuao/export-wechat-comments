# Windows 完整复现：微信公众号公开评论导出为 Markdown

## 目录

1. [目标与边界](#目标与边界)
2. [架构](#架构)
3. [已验证环境](#已验证环境)
4. [依赖安装](#依赖安装)
5. [抓取步骤](#抓取步骤)
6. [实现细节](#实现细节)
7. [安全与清理](#安全与清理)
8. [故障排查](#故障排查)
9. [上游与许可证](#上游与许可证)

## 目标与边界

本流程在 Windows 上复用用户已登录的微信桌面端会话，导出一篇公众号文章公开展示的：

- 精选留言；
- 作者回复；
- 其他用户的公开回复；
- 点赞数与公开时间。

流程不能获取作者未公开的留言。文章页面显示的“留言总数”可能大于公开精选留言数量，这是正常现象；不得把总计数描述成实际导出数量。

本流程会临时进行 TLS 抓包，因此必须获得用户对以下两项操作的明确同意：

- 向当前用户的根证书存储安装一次性 mitmproxy CA；
- 把 WinINET 系统代理临时切换到本地抓包端口。

所有变更都必须按精确记录回滚。不得输出、上传或提交 Cookie、`key`、`uin`、`pass_ticket`、`appmsg_token`、完整凭据 URL 或原始评论 JSON。

## 架构

```text
已登录微信桌面端
      │ 打开目标文章
      ▼
WinINET 临时代理 → wxdown-service / mitmproxy
      │                 │
      │                 └─ credentials.json（临时、敏感）
      ▼
微信公众号评论接口
      │ buffer 分页 + max_reply_id 补抓
      ▼
临时原始 JSON → 去除账号标识 → Markdown
      │
      └─ 恢复代理、停止进程、删除证书与凭据
```

`wechat-article-exporter` 是接口行为和字段结构的上游参考，也可用于其原有网页工作流；本 Skill 为保证 UTF-8、完整分页和最小敏感数据暴露，使用自己的导出脚本直接读取 `wxdown-service` 捕获结果。

## 已验证环境

验证日期：2026-07-26。

- Windows 11；
- 微信桌面端已登录；
- Python 3.12.10；
- mitmproxy 12.1.2；
- Node.js 22 或更高版本；
- `wechat-article/wxdown-service` v0.27.1，提交 `28feff2095359acb158f856c40b357e77b686d2c`；
- `wechat-article/wechat-article-exporter` v2.3.21，提交 `55217d4fdcefd004d42650ebf15116e7b820967a`。

## 依赖安装

安装会联网下载代码和 Python/Node 依赖。由智能体执行时，先向用户说明并获得安装授权。

```powershell
$skill = "C:\path\to\export-wechat-comments"
$deps = "C:\wechat-tools"

& "$skill\scripts\install-dependencies.ps1" -Destination $deps
```

只需要导出评论时，可以跳过 exporter 构建：

```powershell
& "$skill\scripts\install-dependencies.ps1" `
  -Destination $deps `
  -SkipExporter
```

安装脚本会：

1. 克隆固定版本的 `wxdown-service`；
2. 创建 `.venv`；
3. 安装 `requirements.txt`；
4. 可选克隆并构建固定版本的 `wechat-article-exporter`。

## 抓取步骤

### 1. 预检

不要仅检查端口是否正在监听。Windows 的排除端口区间会导致空闲端口绑定时报 `EACCES`，预检脚本会进行真实绑定测试。

```powershell
& "$skill\scripts\preflight.ps1" `
  -WxdownPath "$deps\wxdown-service" `
  -CapturePort 65100 `
  -WssPort 65102
```

如果失败，换用未被占用且不在系统排除区间的端口，再运行一次。

### 2. 启动临时抓包

```powershell
$session = Join-Path $env:TEMP "wechat-comment-capture"

& "$skill\scripts\start-capture.ps1" `
  -WxdownPath "$deps\wxdown-service" `
  -SessionDirectory $session `
  -CapturePort 65100 `
  -WssPort 65102 `
  -WatchdogTimeoutSeconds 900
```

脚本会：

1. 保存 `ProxyEnable`、`ProxyServer`、`AutoConfigURL` 的原值；
2. 启动 `wxdown-service`；
3. 等待 mitmproxy CA 与本地端口就绪；
4. 记录 CA 的 SHA-1 指纹；
5. 只在当前用户根证书存储中安装 CA；
6. 启动超时回滚守护；
7. 把 WinINET 代理切换到本地抓包端口。

会话状态保存在 `$session\capture-state.json`。该文件不含 Cookie，但记录代理和证书清理所需信息；不要提前删除。

### 3. 在微信内打开文章

优先点击聊天中已经存在的公众号文章链接。这样不会产生发送消息、点赞或关注等对外动作。

如果聊天中没有现有链接：

- 让用户手动在微信中打开文章；或
- 在执行发送链接动作前单独请求确认。

不要在未经确认的情况下发送消息、评论、点赞、关注或回复。不要操作 Windows 根证书确认框；如果出现，由用户亲自确认。

### 4. 确认捕获

只检查是否存在目标项，不打印内容：

```powershell
$credentials = "$deps\wxdown-service\resources\data\credentials.json"
$items = Get-Content -Raw -Encoding UTF8 -LiteralPath $credentials | ConvertFrom-Json
[pscustomobject]@{
  captured = Test-Path -LiteralPath $credentials
  entryCount = @($items).Count
}
```

不得显示 `set_cookie` 或 `url` 字段。

### 5. 分页抓取并生成 Markdown

```powershell
& "$skill\scripts\export-comments.ps1" `
  -StatePath "$session\capture-state.json" `
  -ArticleUrl "https://mp.weixin.qq.com/s/ARTICLE_ID" `
  -OutputPath "C:\output\article-comments.md"
```

脚本会自动从抓到的文章页面识别：

- `__biz`；
- `appmsgid` / `mid`；
- `idx`；
- `comment_id`；
- 文章标题；
- 公众号名称。

如果页面结构变化导致 `comment_id` 无法识别，可显式传入：

```powershell
-CommentId "COMMENT_ID_FROM_ARTICLE_HTML"
```

### 6. 无条件清理

成功、失败或中断后都执行：

```powershell
& "$skill\scripts\cleanup-capture.ps1" `
  -StatePath "$session\capture-state.json"
```

如果返回 `certificateNeedsUserAction: true`，Windows 正在等待根证书删除确认。让用户点击确认，然后再次运行同一清理命令。不要替用户点击安全确认框。

## 实现细节

### 凭据来源

`wxdown-service/resources/credential.py` 只在微信文章 `/s?...` 响应中保存临时字段。实践中：

- `key`、`uin` 常在捕获 URL 查询参数中；
- `pass_ticket` 可能同时出现在查询参数和 `Set-Cookie`；
- `appmsg_token` 常在 `Set-Cookie` 中。

只从内存中读取这些字段，不写入命令行、不打印日志、不放入 Markdown。

### 顶级留言分页

评论接口：

```text
https://mp.weixin.qq.com/mp/appmsg_comment?action=getcomment
```

单页通常最多返回 100 条。不要只依赖 `limit=1000`。必须使用响应中的：

- `continue_flag`：是否继续；
- `buffer`：下一页游标。

当 `continue_flag` 为真但 `buffer` 为空或不再变化时停止并报错，避免死循环。

### 回复补抓

顶级留言可能只内嵌部分回复。若：

```text
reply_new.reply_total_cnt != reply_new.reply_list.length
```

调用：

```text
action=getcommentreply
content_id=<留言 ID>
max_reply_id=<reply_new.max_reply_id>
limit=100
```

合并回复时使用 `reply_id + create_time + identity_name + content` 去重。若最终可见数量仍小于计数，通常表示回复已删除或当前不可见；在 Markdown 中保留差异说明。

### UTF-8

Windows PowerShell 5.1 的 `Invoke-WebRequest.Content` 可能错误解码中文。必须从 `RawContentStream` 获取字节并显式按 UTF-8 解码，再执行 `ConvertFrom-Json`。这是避免乱码和无效 JSON 的关键。

### 数据最小化

最终 Markdown 只包含：

- 公开昵称；
- 公开留言/回复正文；
- 时间；
- 点赞数；
- 作者回复标记。

不写入头像 URL、`openid`、`identity_name`、Cookie 或 IP 属地。原始 JSON 仅存在于会话临时目录，渲染后立即删除。

## 安全与清理

清理顺序固定：

1. 恢复原 WinINET 代理并刷新；
2. 停止抓包进程树；
3. 删除 `credentials.json`、临时原始 JSON 和会话日志；
4. 只删除本次会话安装的精确证书指纹；
5. 只删除本次会话创建的 mitmproxy CA 文件；
6. 删除状态文件和空会话目录。

如果用户原本已经有 mitmproxy CA 或 `~/.mitmproxy` 目录，脚本不会删除既有内容。

建议验证：

```powershell
$inet = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
Get-ItemProperty -LiteralPath $inet | Select-Object ProxyEnable,ProxyServer,AutoConfigURL
netstat -ano -p tcp | Select-String ':65100|:65102'
```

## 故障排查

### `listen EACCES`，但端口没有进程

原因通常是 Windows 排除端口区间。运行：

```powershell
netsh interface ipv4 show excludedportrange protocol=tcp
```

换一个通过 `preflight.ps1` 真实绑定测试的端口。

### 匿名评论接口提示“请在微信客户端打开链接”

这是预期行为。必须在已登录微信桌面端打开文章并捕获短期凭据。

### 接口返回 `ret = -1`

常见原因：

- 只读取了 `Set-Cookie`，没有从捕获 URL 读取 `key` / `uin`；
- 缺少 `appmsg_token`；
- 凭据过期；
- 请求缺少微信桌面端 User-Agent 或 Referer。

重新打开文章并立即导出。

### 页面显示 417 条，但只导出 132 条

417 是总留言计数，可能包含未精选或当前不可访问内容。132 才是接口公开返回的 `elected_comment_total_cnt`。这是权限边界，不是分页失败。

### 回复计数比正文多

接口可能保留已删除回复的计数，但不返回正文。记录差异，不伪造内容。

### 清理脚本等待根证书存储

让用户在 Windows 安全窗口中确认删除，再重新运行清理脚本。不得通过 UI 自动化操作安全窗口。

## 上游与许可证

- [wechat-article-exporter](https://github.com/wechat-article/wechat-article-exporter)：MIT；
- [wxdown-service](https://github.com/wechat-article/wxdown-service)：截至验证时 GitHub 未声明许可证；本仓库不复制或再发布其源代码，只由安装脚本从上游获取；
- mitmproxy：按其上游许可证使用。

本 Skill 自身代码使用 MIT 许可证。第三方依赖仍受各自许可证与服务条款约束。使用者应只抓取自己有权访问的公开内容，并遵守适用法律和平台规则。
