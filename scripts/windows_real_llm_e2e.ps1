# Valid Team — Windows Real-LLM + 4-Tool-Chain Clean-VM E2E Sub-Suite (<= 340 lines)
# Invoked by macos/templates/windows_real_e2e.ps1 after POST /setup + va.exe config check.
# Zero-mock anti-fake-green gate: real LLM (VTEAM_TEST_API_KEY only) + triple random nonces.
param(
  [Parameter(Mandatory=$true)][string]$BaseURL,
  [Parameter(Mandatory=$true)][string]$WorkspaceRoot,
  [Parameter(Mandatory=$true)][string]$InstallDir,
  [string]$Model = "",
  [switch]$AllowOfflineSkipRealLLM
)

$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

function Redact-Secret([string]$Text) {
  if ([string]::IsNullOrEmpty($Text)) { return "" }
  $out = $Text
  if (-not [string]::IsNullOrWhiteSpace($env:VTEAM_TEST_API_KEY)) {
    $out = $out.Replace($env:VTEAM_TEST_API_KEY, "[REDACTED]")
  }
  return $out
}

function Get-FreeLoopbackPort {
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  try { return ([System.Net.IPEndPoint]$l.LocalEndpoint).Port } finally { $l.Stop() }
}

function Write-Utf8NoBom([string]$TargetPath, [string]$Text) {
  $parent = Split-Path -Parent $TargetPath
  if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  [System.IO.File]::WriteAllText($TargetPath, $Text, [System.Text.UTF8Encoding]::new($false))
}

function Stop-ProcessTree([int]$ProcId) {
  if ($ProcId -le 0) { return }
  & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $ProcId 2>$null | Out-Null
}

function Invoke-FormPost([string]$Url, [hashtable]$Fields, [switch]$AcceptJson) {
  $pairs = foreach ($k in $Fields.Keys) {
    ("{0}={1}" -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Fields[$k]))
  }
  $bodyBytes = [System.Text.Encoding]::ASCII.GetBytes(($pairs -join "&"))
  $hdrs = @{ "Origin" = $BaseURL; "Sec-Fetch-Site" = "same-origin" }
  if ($AcceptJson) { $hdrs["Accept"] = "application/json" }
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Post -ContentType "application/x-www-form-urlencoded; charset=utf-8" -Headers $hdrs -Body $bodyBytes -TimeoutSec 30 -UseBasicParsing
    return ([string]$resp.Content).Trim()
  } catch {
    $detail = $_.Exception.Message + " " + ($_.ErrorDetails.Message)
    throw ("POST {0} failed: {1}" -f $Url, (Redact-Secret $detail))
  }
}

$isCI = ($env:CI -eq "true")
if ([string]::IsNullOrWhiteSpace($env:VTEAM_TEST_API_KEY)) {
  if ($isCI) {
    throw "CI=true requires VTEAM_TEST_API_KEY for Windows real-LLM E2E (silent skip is strictly forbidden)"
  }
  if ($AllowOfflineSkipRealLLM) {
    Write-Host "   [SKIP] Offline local mode (-AllowOfflineSkipRealLLM): VTEAM_TEST_API_KEY absent."
    exit 0
  }
  throw "VTEAM_TEST_API_KEY is empty (pass -AllowOfflineSkipRealLLM only for offline local debugging)"
}

$apiName = if ($env:VTEAM_TEST_API_NAME) { $env:VTEAM_TEST_API_NAME } else { "opencode-go" }
$apiModel = if ($env:VTEAM_TEST_API_MODEL) { $env:VTEAM_TEST_API_MODEL } else { "deepseek-v4.1-flash" }
$fullModel = if (-not [string]::IsNullOrWhiteSpace($Model)) { $Model } else { "$apiName/$apiModel" }

$runTag = [guid]::NewGuid().ToString("N").Substring(0, 8)
$cmdNonce = "WIN_CMD_NONCE_$runTag"
$fetchNonce = "WIN_FETCH_NONCE_$runTag"
$browserNonce = "WIN_BROWSER_NONCE_$runTag"
$childMarker = "VT_WIN_GRANDCHILD_$runTag"
$httpPort = Get-FreeLoopbackPort
$tmpBase = if (-not [string]::IsNullOrWhiteSpace($env:RUNNER_TEMP)) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$hitLogFile = Join-Path $tmpBase "win-real-llm-hits-$runTag.log"
$cmdProofFile = Join-Path $tmpBase "win-real-llm-cmd-proof-$runTag.txt"
Remove-Item -LiteralPath $hitLogFile, $cmdProofFile -Force -ErrorAction SilentlyContinue

Write-Host "==> [Win-Real-LLM-E2E] Starting local UTF-8/JS fixture HTTP server on 127.0.0.1:$httpPort (nonces: $runTag)..."
$httpJob = Start-Job -ArgumentList $httpPort, $cmdNonce, $fetchNonce, $browserNonce, $runTag, $hitLogFile -ScriptBlock {
  param($port, $cNonce, $fNonce, $bNonce, $tag, $logFile)
  $listener = [System.Net.HttpListener]::new()
  $listener.Prefixes.Add("http://127.0.0.1:$port/")
  $listener.Start()
  $enc = [System.Text.UTF8Encoding]::new($false)
  try {
    $ar = $null
    while ($listener.IsListening) {
      if ($null -eq $ar) {
        try { $ar = $listener.BeginGetContext($null, $null) } catch { break }
      }
      if (-not $ar.AsyncWaitHandle.WaitOne(150)) { continue }
      try { $ctx = $listener.EndGetContext($ar) } catch { break } finally { $ar = $null }
      $path = $ctx.Request.Url.AbsolutePath
      if ($path -eq "/__shutdown") {
        $bye = $enc.GetBytes("BYE")
        $ctx.Response.ContentLength64 = $bye.Length
        $ctx.Response.OutputStream.Write($bye, 0, $bye.Length)
        $ctx.Response.OutputStream.Close()
        break
      }
      [System.IO.File]::AppendAllText($logFile, ($path + "`n"), $enc)
      if ($path -eq "/health") {
        $body = "OK"
        $ctx.Response.ContentType = "text/plain; charset=utf-8"
      } elseif ($path -eq "/cmd-nonce-$tag") {
        $body = $cNonce
        $ctx.Response.ContentType = "text/plain; charset=utf-8"
      } elseif ($path -eq "/fetch-zh") {
        $body = "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><title>中文抓取页</title></head><body><h1>中文测试页</h1><div id='fetch-token'>loading</div><script>document.getElementById('fetch-token').textContent='$fNonce';</script></body></html>"
        $ctx.Response.ContentType = "text/html; charset=utf-8"
      } elseif ($path -eq "/browser-zh") {
        $body = "<!doctype html><html lang='zh-CN'><head><meta charset='utf-8'><title>中文浏览器验收页</title></head><body><h1>托管浏览器中文测试</h1><button id='ok-btn'>确认验收</button><p id='browser-token'>loading</p><script>document.getElementById('browser-token').textContent='$bNonce';</script></body></html>"
        $ctx.Response.ContentType = "text/html; charset=utf-8"
      } else {
        $ctx.Response.StatusCode = 404
        $body = "not found"
      }
      $buf = $enc.GetBytes($body)
      $ctx.Response.ContentLength64 = $buf.Length
      $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
      $ctx.Response.OutputStream.Close()
    }
  } finally {
    try { $listener.Stop(); $listener.Close() } catch {}
  }
}

$projName = "真模型实战项目 #1"
$encProj = [uri]::EscapeDataString($projName)
$projDir = Join-Path $WorkspaceRoot $projName

try {
  $fixtureReady = $false
  for ($i = 0; $i -lt 30; $i++) {
    try {
      $h = Invoke-RestMethod -Uri "http://127.0.0.1:$httpPort/health" -TimeoutSec 2
      if ($h -eq "OK") { $fixtureReady = $true; break }
    } catch {}
    Start-Sleep -Milliseconds 300
  }
  if (-not $fixtureReady) { throw "Local fixture HTTP server failed to start on 127.0.0.1:$httpPort" }

  Write-Host "   -> Creating Chinese+Space project '$projName', role 'dev' ($fullModel) & enabling managed browser..."
  Invoke-FormPost "$BaseURL/projects" @{ name = $projName } | Out-Null
  if (-not (Test-Path -LiteralPath (Join-Path $projDir "state.db"))) {
    throw "Project creation did not materialize state.db under $projDir"
  }

  $rolePrompt = "你是Windows端到端验收工程师(dev)。严格按任务单逐项真实调用 run_command、web_fetch、browser_navigate、browser_snapshot、read_file、write_file、edit_file 和 complete_task，禁止编造工具结果。"
  Invoke-FormPost "$BaseURL/projects/$encProj/roles" @{
    id         = "dev"
    name       = "验收工程师"
    model      = $fullModel
    work_start = "00:00"
    work_end   = "23:59"
    skills     = "上下班流程,资产读写维护,Chrome网页读取,脚本与数据库执行,浏览器操控"
    duty       = "letter"
    prompt     = $rolePrompt
  } | Out-Null

  $browserCfgBody = '{"enabled":true,"mode":"managed","role_skills":{"dev":true}}'
  $browserCfgResp = Invoke-RestMethod -Uri "$BaseURL/projects/$encProj/browser/config" -Method Post -ContentType "application/json; charset=utf-8" -Headers @{ "Origin" = $BaseURL; "Sec-Fetch-Site" = "same-origin" } -Body $browserCfgBody -TimeoutSec 10
  if (-not $browserCfgResp) { throw "Failed to enable managed browser for $projName" }

  # Prepare run_command probe script inside dev's work dir: fetches nonce from fixture server & writes proof outside dev's work dir (immune to agent workspace cleanup & read-file bypass)
  $devWorkDir = Join-Path $projDir "roles\dev\work"
  $cmdHelperPath = Join-Path $devWorkDir "emit_cmd_nonce.ps1"
  $cmdProofEsc = $cmdProofFile.Replace("'", "''")
  $cmdHelperBody = @"
[System.IO.File]::WriteAllText('$cmdProofEsc', '$runTag', [System.Text.UTF8Encoding]::new(`$false))
`$wc = New-Object System.Net.WebClient
`$wc.Proxy = `$null
`$wc.Encoding = [System.Text.Encoding]::UTF8
`$token = `$wc.DownloadString('http://127.0.0.1:$httpPort/cmd-nonce-$runTag').Trim()
Write-Output "WIN_CMD_ZH_OK_中文"
Write-Output "CMD_NONCE=`$token"
& cmd.exe /d /c "echo $childMarker >nul"
exit 17
"@
  Write-Utf8NoBom $cmdHelperPath $cmdHelperBody

  $reportRel = "分析报告/真机验收/中文 交付 报告.md"
  $reportPath = Join-Path $projDir "workspace\分析报告\真机验收\中文 交付 报告.md"
  $auxPath = Join-Path $projDir "workspace\分析报告\真机验收\cmd回执 中文.txt"
  $seedContent = "# Windows 真机模型实战验收报告`r`n`r`n- 初始环境：含中文与空格路径`r`n- 待填充区：PLACEHOLDER_REPLACE_ME_中文`r`n"
  Write-Utf8NoBom $reportPath $seedContent

  $taskBody = @"
请按以下 5 步在当前项目中真实调用工具完成 Windows 端到端验收（严禁猜测或编造结果，且不要删除夹具脚本 emit_cmd_nonce.ps1）：
1. 调用 run_command 执行：powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\emit_cmd_nonce.ps1
   从真实命令输出中记录中文回执 WIN_CMD_ZH_OK_中文、CMD_NONCE= 后面的动态令牌（以 WIN_CMD_NONCE_ 开头）以及非零退出码 17。
2. 调用 web_fetch，参数 url="http://127.0.0.1:$httpPort/fetch-zh" 且 render_js=true，读取页面中的 WIN_FETCH_NONCE_ 开头的完整令牌。
3. 依次调用 browser_navigate(url="http://127.0.0.1:$httpPort/browser-zh") 与 browser_snapshot()，读取页面中的 WIN_BROWSER_NONCE_ 开头的完整令牌。
4. 调用 read_file 读取 "$reportRel"，调用 write_file 将步骤1的中文回执 WIN_CMD_ZH_OK_中文、动态 CMD_NONCE 完整令牌和退出码 17 写入 "分析报告/真机验收/cmd回执 中文.txt"，再调用 edit_file 将 "$reportRel" 中的 PLACEHOLDER_REPLACE_ME_中文 精确替换为：
   CMD=WIN_CMD_ZH_OK_中文 | CMD_NONCE=<步骤1动态令牌> | EXIT_CODE=17 | FETCH=<步骤2完整令牌> | BROWSER=<步骤3完整令牌>
5. 全部落盘后立即调用 complete_task(outcome="success", deliverables=["$reportRel", "分析报告/真机验收/cmd回执 中文.txt"], summary="Windows四类工具链真机实测完成") 结单。
"@

  Write-Host "   -> Dispatching real-LLM 4-tool-chain directive to role 'dev'..."
  $dirRespRaw = Invoke-FormPost "$BaseURL/projects/$encProj/directives" @{
    from    = "boss"
    to      = "dev"
    type    = "task"
    kind    = "mail"
    subject = "Windows真机四类工具链端到端验收"
    body    = $taskBody
  } -AcceptJson
  $dirResp = $dirRespRaw | ConvertFrom-Json
  if (-not $dirResp.ok -or [string]::IsNullOrWhiteSpace($dirResp.id)) {
    throw "Directive dispatch failed: $(Redact-Secret $dirRespRaw)"
  }
  $directiveId = [string]$dirResp.id
  Write-Host "   -> Directive dispatched (id=$directiveId); waiting up to 240s for real LLM completion..."

  $completed = $false
  $lastStatus = $null
  for ($sec = 1; $sec -le 240; $sec++) {
    $st = Invoke-RestMethod -Uri "$BaseURL/api/status" -TimeoutSec 5
    $lastStatus = $st
    $running = [int]($st.running_task_count) + [int]($st.working_role_count)
    if ($sec -ge 4 -and $running -eq 0) {
      Start-Sleep -Seconds 2
      $st2 = Invoke-RestMethod -Uri "$BaseURL/api/status" -TimeoutSec 5
      $running2 = [int]($st2.running_task_count) + [int]($st2.working_role_count)
      if ($running2 -eq 0) { $completed = $true; Write-Host "   -> Real-LLM directive finished at ${sec}s."; break }
    }
    Start-Sleep -Seconds 1
  }
  if (-not $completed) {
    throw ("Real-LLM directive {0} timed out after 240s (status={1})" -f $directiveId, (Redact-Secret ($lastStatus | ConvertTo-Json -Compress)))
  }

  # Strictly verify directive closed cleanly with success (never allow failed/blocked/partial)
  $drawerHtml = [string](Invoke-WebRequest -Uri "$BaseURL/projects/$encProj/directives/$directiveId/drawer?view=overview" -UseBasicParsing -TimeoutSec 10).Content
  if ($drawerHtml -match 'outcome-conclusion-banner is-(failed|blocked|partial)' -or $drawerHtml -match 'outcome-error-box' -or $drawerHtml -match 'result-card is-(ended|partial)') {
    throw "Directive $directiveId did NOT close with clean success outcome"
  }
  if ($drawerHtml -notmatch 'result-card is-done' -and $drawerHtml -notmatch '已交付') {
    throw "Directive $directiveId drawer missing success delivery card (result-card is-done)"
  }

  # Hard anti-fake-green disk byte assertions: physical run_command proof + triple random nonces + UTF-8 no-BOM + 0 U+FFFD
  $hits = if (Test-Path -LiteralPath $hitLogFile) { @(Get-Content -LiteralPath $hitLogFile) } else { @() }
  if (-not (Test-Path -LiteralPath $cmdProofFile) -or ((Get-Content -LiteralPath $cmdProofFile -Raw).Trim() -ne $runTag)) {
    throw ("Missing physical run_command execution proof file: {0} (hits={1}, reportExists={2})" -f $cmdProofFile, ($hits -join ","), (Test-Path -LiteralPath $reportPath))
  }
  if (-not (Test-Path -LiteralPath $reportPath)) { throw "Missing deliverable file: $reportPath" }
  if (-not (Test-Path -LiteralPath $auxPath)) { throw "Missing write_file deliverable: $auxPath" }

  $rawBytes = [System.IO.File]::ReadAllBytes($reportPath)
  if ($rawBytes.Length -eq 0) { throw "Deliverable report is empty: $reportPath" }
  if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
    throw "Deliverable report corrupted with unexpected UTF-8 BOM: $reportPath"
  }
  $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
  $reportText = $utf8Strict.GetString($rawBytes)
  if ($reportText.Contains([char]0xFFFD)) { throw "Deliverable report contains U+FFFD replacement char (mojibake)" }
  if ($reportText -match "PLACEHOLDER_REPLACE_ME_中文") { throw "edit_file did not replace placeholder in $reportPath" }
  if ($reportText -notmatch [regex]::Escape($cmdNonce)) { throw "Deliverable missing dynamic run_command random nonce ($cmdNonce)" }
  if ($reportText -notmatch [regex]::Escape($fetchNonce)) { throw "Deliverable missing real web_fetch random nonce ($fetchNonce)" }
  if ($reportText -notmatch [regex]::Escape($browserNonce)) { throw "Deliverable missing real browser_snapshot random nonce ($browserNonce)" }
  if ($reportText -notmatch "WIN_CMD_ZH_OK_中文" -or $reportText -notmatch "17") {
    throw "Deliverable missing run_command Chinese receipt or exit code 17"
  }

  $auxBytes = [System.IO.File]::ReadAllBytes($auxPath)
  if ($auxBytes.Length -eq 0) { throw "Aux write_file deliverable is empty: $auxPath" }
  $auxText = $utf8Strict.GetString($auxBytes)
  if ($auxText.Contains([char]0xFFFD)) { throw "Aux write_file deliverable contains U+FFFD mojibake" }
  if ($auxText -notmatch [regex]::Escape($cmdNonce) -or $auxText -notmatch "WIN_CMD_ZH_OK_中文" -or $auxText -notmatch "17") {
    throw "Aux write_file deliverable missing dynamic cmd nonce ($cmdNonce), Chinese receipt, or exit code 17"
  }

  # Verify local fixture HTTP server actually received /cmd-nonce, /fetch-zh and /browser-zh hits
  $cmdHits = @($hits | Where-Object { $_ -eq "/cmd-nonce-$runTag" }).Count
  $fetchHits = @($hits | Where-Object { $_ -eq "/fetch-zh" }).Count
  $browserHits = @($hits | Where-Object { $_ -eq "/browser-zh" }).Count
  if ($cmdHits -lt 1) { throw "Fixture HTTP server recorded 0 hits on /cmd-nonce-$runTag (emit_cmd_nonce.ps1 did not execute)" }
  if ($fetchHits -lt 1) { throw "Fixture HTTP server recorded 0 hits on /fetch-zh (web_fetch did not execute)" }
  if ($browserHits -lt 1) { throw "Fixture HTTP server recorded 0 hits on /browser-zh (managed browser did not navigate)" }
  Write-Host "   [PASS] Triple random nonces + 4-tool chain verified (cmdProof=OK, cmdHits=$cmdHits, fetchHits=$fetchHits, browserHits=$browserHits, UTF-8 no-BOM, 0 U+FFFD)!"

  # Stop managed browser & assert zero grandchild / managed browser leaks
  try {
    Invoke-RestMethod -Uri "$BaseURL/projects/$encProj/browser/stop" -Method Post -Headers @{ "Origin" = $BaseURL; "Sec-Fetch-Site" = "same-origin" } -TimeoutSec 10 | Out-Null
  } catch {}
  Start-Sleep -Seconds 2

  $leakedChild = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.Contains($childMarker) })
  if ($leakedChild.Count -gt 0) {
    foreach ($p in $leakedChild) { Stop-ProcessTree ([int]$p.ProcessId) }
    throw "Leaked grandchild process detected with marker $childMarker (count=$($leakedChild.Count))"
  }
  $leakedBrowser = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    ($_.Name -match "^(msedge|chrome)\.exe$") -and $_.CommandLine -and ($_.CommandLine.Contains($projName) -or $_.CommandLine.Contains("browser-profile"))
  })
  if ($leakedBrowser.Count -gt 0) {
    foreach ($p in $leakedBrowser) { Stop-ProcessTree ([int]$p.ProcessId) }
    throw "Leaked managed browser process detected after browser/stop (count=$($leakedBrowser.Count))"
  }
  Write-Host "   [PASS] WIN_REAL_LLM_E2E_OK: Real LLM + run_command + file tools + web_fetch + managed browser_* + 0 process leak verified!"
} finally {
  try {
    Invoke-RestMethod -Uri "$BaseURL/projects/$encProj/browser/stop" -Method Post -Headers @{ "Origin" = $BaseURL; "Sec-Fetch-Site" = "same-origin" } -TimeoutSec 5 | Out-Null
  } catch {}
  if ($httpJob) {
    try { Invoke-RestMethod -Uri "http://127.0.0.1:$httpPort/__shutdown" -TimeoutSec 2 -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Wait-Job -Job $httpJob -Timeout 3 -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Stop-Job -Job $httpJob -ErrorAction SilentlyContinue } catch {}
    try { Remove-Job -Job $httpJob -Force -ErrorAction SilentlyContinue } catch {}
  }
  Remove-Item -LiteralPath $hitLogFile, $cmdProofFile -Force -ErrorAction SilentlyContinue
}
