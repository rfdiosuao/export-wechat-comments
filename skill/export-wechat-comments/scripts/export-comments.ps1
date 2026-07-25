[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$StatePath,
    [Parameter(Mandatory = $true)][string]$OutputPath,
    [string]$ArticleUrl = '',
    [string]$Title = '',
    [string]$AccountName = '',
    [string]$CommentId = '',
    [switch]$KeepRaw
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Web

function Get-Utf8Body($Response) {
    $bytes = $Response.RawContentStream.ToArray()
    return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Get-PlainText([string]$HtmlFragment) {
    $withoutTags = [regex]::Replace($HtmlFragment, '<[^>]+>', ' ')
    return [System.Net.WebUtility]::HtmlDecode($withoutTags).Trim()
}

$resolvedStatePath = [System.IO.Path]::GetFullPath($StatePath)
$resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$state = Get-Content -Raw -Encoding UTF8 -LiteralPath $resolvedStatePath | ConvertFrom-Json
$credentialsPath = [string]$state.credentialsPath
if (-not (Test-Path -LiteralPath $credentialsPath -PathType Leaf)) {
    throw 'No captured credential file was found. Open the article inside logged-in WeChat first.'
}

$credentialItems = @(Get-Content -Raw -Encoding UTF8 -LiteralPath $credentialsPath | ConvertFrom-Json)
$credential = $credentialItems | Sort-Object -Property timestamp -Descending | Select-Object -First 1
if ($null -eq $credential -or [string]::IsNullOrWhiteSpace([string]$credential.url)) {
    throw 'The captured credential entry is incomplete.'
}

$capturedUri = [System.Uri]([string]$credential.url)
$capturedQuery = [System.Web.HttpUtility]::ParseQueryString($capturedUri.Query)
$biz = [string]$capturedQuery['__biz']
$appmsgId = [string]$capturedQuery['mid']
if ([string]::IsNullOrWhiteSpace($appmsgId)) { $appmsgId = [string]$capturedQuery['appmsgid'] }
$itemIndex = [string]$capturedQuery['idx']
if ([string]::IsNullOrWhiteSpace($itemIndex)) { $itemIndex = '1' }
if ([string]::IsNullOrWhiteSpace($biz) -or [string]::IsNullOrWhiteSpace($appmsgId)) {
    throw 'Could not derive __biz and appmsgid from the captured article URL.'
}

$cookieValues = @{}
$allowedCookieNames = @(
    'appmsg_token', 'devicetype', 'lang', 'mallkey', 'malluin', 'pass_ticket',
    'payforreadsn', 'rewardsn', 'version', 'wap_sid2', 'wxtokenkey', 'wxuin'
)
[regex]::Matches([string]$credential.set_cookie, '(?:^|,\s*|;\s*)(?<name>[A-Za-z0-9_]+)=(?<value>[^;,]+)') |
    Where-Object { $allowedCookieNames -contains $_.Groups['name'].Value } |
    ForEach-Object { $cookieValues[$_.Groups['name'].Value] = $_.Groups['value'].Value }
foreach ($name in @('key', 'uin', 'pass_ticket')) {
    if (-not [string]::IsNullOrWhiteSpace([string]$capturedQuery[$name])) {
        $cookieValues[$name] = [string]$capturedQuery[$name]
    }
}
foreach ($requiredName in @('key', 'uin', 'pass_ticket', 'appmsg_token')) {
    if ([string]::IsNullOrWhiteSpace([string]$cookieValues[$requiredName])) {
        throw "Captured credential is missing $requiredName. Reopen the article and retry."
    }
}

$cookieHeader = ($cookieValues.GetEnumerator() |
    Where-Object { $_.Key -notin @('key', 'uin') } |
    ForEach-Object { "$($_.Key)=$($_.Value)" }) -join '; '
$headers = @{
    Cookie = $cookieHeader
    Referer = 'https://mp.weixin.qq.com/'
}
$userAgent = 'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/107.0.0.0 Safari/537.36 MicroMessenger/6.8.0(0x16080000) NetType/WIFI MiniProgramEnv/Mac MacWechat/WECHAT/WeChatBrowser XWEB/1191'

$articleResponse = Invoke-WebRequest -UseBasicParsing -Uri ([string]$credential.url) -Headers $headers -UserAgent $userAgent -TimeoutSec 60
$articleHtml = Get-Utf8Body $articleResponse

if ([string]::IsNullOrWhiteSpace($Title)) {
    $titleMatch = [regex]::Match($articleHtml, '(?is)<h1[^>]*id=["'']activity-name["''][^>]*>(?<value>.*?)</h1>')
    if ($titleMatch.Success) { $Title = Get-PlainText $titleMatch.Groups['value'].Value }
}
if ([string]::IsNullOrWhiteSpace($AccountName)) {
    $AccountName = [string]$credential.name
}
if ([string]::IsNullOrWhiteSpace($CommentId)) {
    $patterns = @(
        '(?<![A-Za-z0-9_])comment_id\s*:\s*JsDecode\(["''](?<id>\d+)["'']\)',
        'var\s+comment_id\s*=\s*["''](?<id>\d+)["'']'
    )
    foreach ($pattern in $patterns) {
        $match = [regex]::Match($articleHtml, $pattern)
        if ($match.Success) {
            $CommentId = $match.Groups['id'].Value
            break
        }
    }
}
if ([string]::IsNullOrWhiteSpace($CommentId)) {
    throw 'Could not derive comment_id from the article HTML. Pass -CommentId explicitly.'
}
if ([string]::IsNullOrWhiteSpace($Title)) { $Title = 'WeChat article comments' }
if ([string]::IsNullOrWhiteSpace($AccountName)) { $AccountName = 'Unknown account' }
if ([string]::IsNullOrWhiteSpace($ArticleUrl)) {
    $safeQuery = [System.Web.HttpUtility]::ParseQueryString('')
    $safeQuery['__biz'] = $biz
    $safeQuery['mid'] = $appmsgId
    $safeQuery['idx'] = $itemIndex
    if (-not [string]::IsNullOrWhiteSpace([string]$capturedQuery['sn'])) {
        $safeQuery['sn'] = [string]$capturedQuery['sn']
    }
    $ArticleUrl = 'https://mp.weixin.qq.com/s?' + $safeQuery.ToString()
}

function Invoke-WeChatJson($Query) {
    $uri = 'https://mp.weixin.qq.com/mp/appmsg_comment?' + $Query.ToString()
    $response = Invoke-WebRequest -UseBasicParsing -Uri $uri -Headers $headers -UserAgent $userAgent -TimeoutSec 60
    $text = Get-Utf8Body $response
    return $text | ConvertFrom-Json
}

$query = [System.Web.HttpUtility]::ParseQueryString('')
$query['action'] = 'getcomment'
$query['scene'] = '0'
$query['appmsgid'] = $appmsgId
$query['idx'] = $itemIndex
$query['__biz'] = $biz
$query['comment_id'] = $CommentId
$query['key'] = $cookieValues['key']
$query['uin'] = $cookieValues['uin']
$query['pass_ticket'] = $cookieValues['pass_ticket']
$query['appmsg_token'] = $cookieValues['appmsg_token']
$query['wxtoken'] = '777'
$query['devicetype'] = 'UnifiedPCMac'
$query['comment_scene'] = '0'
$query['offset'] = '0'
$query['limit'] = '100'
$query['x5'] = '0'
$query['f'] = 'json'

$allComments = [System.Collections.Generic.List[object]]::new()
$firstPage = $null
$nextBuffer = ''
for ($page = 1; $page -le 50; $page++) {
    $query['buffer'] = $nextBuffer
    $parsed = Invoke-WeChatJson $query
    if ($null -ne $parsed.base_resp -and [int]$parsed.base_resp.ret -ne 0) {
        throw "The WeChat comment endpoint returned error $($parsed.base_resp.ret)."
    }
    if ($null -eq $firstPage) { $firstPage = $parsed }
    foreach ($comment in @($parsed.elected_comment)) { $allComments.Add($comment) }
    if (-not [bool]$parsed.continue_flag) { break }
    $newBuffer = [string]$parsed.buffer
    if ([string]::IsNullOrWhiteSpace($newBuffer) -or $newBuffer -eq $nextBuffer) {
        throw 'The top-level comment cursor did not advance.'
    }
    $nextBuffer = $newBuffer
}
if ($null -eq $firstPage) { throw 'The comment endpoint returned no pages.' }
$firstPage.elected_comment = @($allComments.ToArray())

foreach ($comment in $firstPage.elected_comment) {
    if ($null -eq $comment.reply_new) { continue }
    $existingReplies = @($comment.reply_new.reply_list)
    if ([int]$comment.reply_new.reply_total_cnt -le $existingReplies.Count) { continue }

    $replyQuery = [System.Web.HttpUtility]::ParseQueryString('')
    $replyQuery['action'] = 'getcommentreply'
    $replyQuery['scene'] = '0'
    $replyQuery['appmsgid'] = $appmsgId
    $replyQuery['idx'] = $itemIndex
    $replyQuery['__biz'] = $biz
    $replyQuery['comment_id'] = $CommentId
    $replyQuery['uin'] = $cookieValues['uin']
    $replyQuery['key'] = $cookieValues['key']
    $replyQuery['pass_ticket'] = $cookieValues['pass_ticket']
    $replyQuery['appmsg_token'] = $cookieValues['appmsg_token']
    $replyQuery['wxtoken'] = '777'
    $replyQuery['devicetype'] = 'UnifiedPCMac'
    $replyQuery['content_id'] = [string]$comment.content_id
    $replyQuery['max_reply_id'] = [string]$comment.reply_new.max_reply_id
    $replyQuery['limit'] = '100'
    $replyQuery['x5'] = '0'
    $replyQuery['f'] = 'json'

    $replyParsed = Invoke-WeChatJson $replyQuery
    if ($null -ne $replyParsed.base_resp -and [int]$replyParsed.base_resp.ret -ne 0) {
        throw "The WeChat reply endpoint returned error $($replyParsed.base_resp.ret)."
    }
    $mergedReplies = [System.Collections.Generic.List[object]]::new()
    $seenReplies = @{}
    foreach ($reply in @($existingReplies) + @($replyParsed.reply_list.reply_list)) {
        $replyKey = "$($reply.reply_id)|$($reply.create_time)|$($reply.identity_name)|$($reply.content)"
        if (-not $seenReplies.ContainsKey($replyKey)) {
            $seenReplies[$replyKey] = $true
            $mergedReplies.Add($reply)
        }
    }
    $comment.reply_new.reply_list = @($mergedReplies.ToArray())
}

$outputDirectory = Split-Path -Parent $resolvedOutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDirectory)) {
    [System.IO.Directory]::CreateDirectory($outputDirectory) | Out-Null
}
$rawPath = Join-Path ([string]$state.sessionDirectory) ("comments-{0}.json" -f [guid]::NewGuid().ToString('N'))
try {
    [System.IO.File]::WriteAllText(
        $rawPath,
        ($firstPage | ConvertTo-Json -Depth 100),
        [System.Text.UTF8Encoding]::new($false)
    )
    $renderer = Join-Path $PSScriptRoot 'render-comments.mjs'
    & node $renderer $rawPath $resolvedOutputPath $Title $ArticleUrl $AccountName
    if ($LASTEXITCODE -ne 0) { throw 'Markdown rendering failed.' }
} finally {
    if (-not $KeepRaw -and (Test-Path -LiteralPath $rawPath)) {
        [System.IO.File]::Delete($rawPath)
    }
}

$visibleReplies = 0
$declaredReplies = 0
foreach ($comment in $firstPage.elected_comment) {
    $visibleReplies += @($comment.reply_new.reply_list).Count
    $declaredReplies += [int]$comment.reply_new.reply_total_cnt
}
[pscustomobject]@{
    outputPath = $resolvedOutputPath
    totalMessageCount = [int]$firstPage.total_count
    publicSelectedComments = $allComments.Count
    visibleReplies = $visibleReplies
    declaredReplies = $declaredReplies
} | ConvertTo-Json -Compress
