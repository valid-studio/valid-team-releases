# Valid Team — Windows Dirty-Env, CP936, Auth Proxy & Real Desktop Shell Icon/DPI E2E Sub-Suite (<= 380 lines)
# Invoked by macos/templates/windows_real_e2e.ps1 after primary daemon teardown (clean process table).
param(
  [Parameter(Mandatory=$true)][string]$SetupExe,
  [string]$DownloadDir = ""
)
$ErrorActionPreference = "Stop"
$OutputEncoding = [Console]::InputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
if (-not (Test-Path -LiteralPath $SetupExe)) { throw "Missing SetupExe: $SetupExe" }

function Get-FreeLoopbackPort {
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $l.Start()
  try { return ([System.Net.IPEndPoint]$l.LocalEndpoint).Port } finally { $l.Stop() }
}
function Write-Utf8NoBom([string]$TargetPath, [string]$Text) {
  $p = Split-Path -Parent $TargetPath
  if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  [System.IO.File]::WriteAllText($TargetPath, $Text, [System.Text.UTF8Encoding]::new($false))
}
function Invoke-FormPost([string]$Url, [string]$Origin, [hashtable]$Fields) {
  $pairs = foreach ($k in $Fields.Keys) { "{0}={1}" -f [uri]::EscapeDataString([string]$k), [uri]::EscapeDataString([string]$Fields[$k]) }
  $bytes = [System.Text.Encoding]::ASCII.GetBytes(($pairs -join "&"))
  return Invoke-WebRequest -Uri $Url -Method Post -ContentType "application/x-www-form-urlencoded; charset=utf-8" -Headers @{ "Origin" = $Origin; "Sec-Fetch-Site" = "same-origin" } -Body $bytes -TimeoutSec 20 -UseBasicParsing
}
function Stop-ProcessTree([int]$ProcId) { if ($ProcId -gt 0) { & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $ProcId 2>$null | Out-Null } }
function Remove-DirRetry([string]$DirPath, [int]$MaxAttempts = 12) {
  for ($i = 1; $i -le $MaxAttempts; $i++) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    Remove-Item -LiteralPath $DirPath -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    Start-Sleep -Milliseconds 400
  }
}
function Wait-VteamReady([System.Diagnostics.Process]$Proc, [string]$BaseURL, [string]$Label) {
  for ($i = 0; $i -lt 50; $i++) {
    if ($Proc.HasExited) { throw "$Label vteam.exe exited prematurely (code=$($Proc.ExitCode))" }
    try { $st = Invoke-RestMethod -Uri "$BaseURL/api/status" -TimeoutSec 2; if ($st -and $st.daemon_health) { return $st } } catch {}
    Start-Sleep -Milliseconds 300
  }
  throw "$Label vteam.exe did not become ready at $BaseURL"
}

$runId = [guid]::NewGuid().ToString("N").Substring(0, 6)
$dirtyRoot = Join-Path $env:RUNNER_TEMP ("张伟 的 电脑 (验收 $runId)")
$dirtyHome = Join-Path $dirtyRoot "用户 目录 中文"
$dirtyLocalAppData = Join-Path $dirtyRoot "本地 数据 中文"
$dirtyAppData = Join-Path $dirtyRoot "漫游 数据 中文"
$dirtyTemp = Join-Path $dirtyRoot "临时 缓存 中文"
$dirtyCodex = Join-Path $dirtyRoot "自定义 codex 目录"
$dirtyInstall = Join-Path $dirtyRoot "软件安装 Valid Team"
$dirtyWork = Join-Path $dirtyRoot "项目 工作区 中文"
$dirtySec = Join-Path $dirtyRoot "security.toml"
$outLog = Join-Path $env:RUNNER_TEMP "win-dirty-vteam-out-$runId.log"
$errLog = Join-Path $env:RUNNER_TEMP "win-dirty-vteam-err-$runId.log"
$proxyHitLog = Join-Path $env:RUNNER_TEMP "win-dirty-proxy-hits-$runId.log"
$proxyStopFlag = Join-Path $env:RUNNER_TEMP "win-dirty-proxy-stop-$runId.flag"
$proxyPass = "VtProxyPass99!"; $proxyUser = "vtuser"
$proxyB64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("${proxyUser}:${proxyPass}"))

$envKeys = @("USERPROFILE","HOME","LOCALAPPDATA","APPDATA","TEMP","TMP","CODEX_HOME","http_proxy","Https_Proxy","ALL_PROXY","no_proxy","VTEAM_HEADLESS_TEST")
$savedEnv = @{}
foreach ($k in $envKeys) { $savedEnv[$k] = [System.Environment]::GetEnvironmentVariable($k, "Process") }
$daemon1 = $null; $daemon2 = $null; $guiProc = $null; $proxyJob = $null

try {
  foreach ($d in @($dirtyRoot, $dirtyHome, $dirtyLocalAppData, $dirtyAppData, $dirtyTemp, $dirtyCodex, $dirtyWork)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }

  # 1) Custom /DIR silent install + Chinese+Space env vars + SQLite WAL/VACUUM INTO + prepare CP936 CLI & auth proxy before hot restart
  Write-Host "==> [Win-Dirty-E2E 1/4] Silent install to Chinese+Space /DIR & WAL/VACUUM INTO..."
  $env:USERPROFILE = $dirtyHome; $env:HOME = $dirtyHome; $env:LOCALAPPDATA = $dirtyLocalAppData; $env:APPDATA = $dirtyAppData
  $env:TEMP = $dirtyTemp; $env:TMP = $dirtyTemp; $env:CODEX_HOME = $dirtyCodex

  $instProc = Start-Process -FilePath $SetupExe -ArgumentList @("/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/DIR=`"$dirtyInstall`"") -Wait -PassThru
  if ($instProc.ExitCode -ne 0) { throw "Custom /DIR silent install failed (exit=$($instProc.ExitCode))" }
  $dGuiExe = Join-Path $dirtyInstall "ValidTeam.exe"; $dVteamExe = Join-Path $dirtyInstall "vteam.exe"; $dVaExe = Join-Path $dirtyInstall "va.exe"
  foreach ($exe in @($dGuiExe, $dVteamExe, $dVaExe)) { if (-not (Test-Path -LiteralPath $exe) -or (Get-Item -LiteralPath $exe).Length -le 0) { throw "Missing installed binary: $exe" } }

  [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
  $gbk = [System.Text.Encoding]::GetEncoding(936)
  $gbkOutFile = Join-Path $dirtyTemp "cp936_out.bin"; $gbkErrFile = Join-Path $dirtyTemp "cp936_err.bin"
  $cp936Marker = Join-Path $dirtyTemp "cp936_ran_$runId.txt"; $cp936Cmd = Join-Path $dirtyTemp "cp936_probe.cmd"
  [System.IO.File]::WriteAllBytes($gbkOutFile, $gbk.GetBytes("CP936_中文回执_OK`r`n"))
  [System.IO.File]::WriteAllBytes($gbkErrFile, $gbk.GetBytes("CP936_中文错误_ERR`r`n"))
  $cmdBody = "@echo off`r`nchcp 936 >nul`r`n> `"$cp936Marker`" echo $runId`r`ntype `"$gbkOutFile`"`r`ntype `"$gbkErrFile`" 1>&2`r`nexit /b 23`r`n"
  [System.IO.File]::WriteAllBytes($cp936Cmd, $gbk.GetBytes($cmdBody))
  $cp936CmdToml = $cp936Cmd.Replace('\', '\\')

  $secToml = "default_model = `"selftest/mock`"`n`n[[api]]`nname = `"selftest`"`nformat = `"openai`"`nbase_url = `"http://127.0.0.1:9/v1`"`nkey = `"sk-selftest-placeholder`"`nmodels = [`"mock`"]`n`n[[api]]`nname = `"cp936probe`"`nformat = `"cli`"`ncommand = `"$cp936CmdToml`"`nmodels = [`"probe`"]`n"
  Write-Utf8NoBom $dirtySec $secToml

  $p1 = Get-FreeLoopbackPort; $addr1 = "127.0.0.1:$p1"; $url1 = "http://$addr1"
  $daemon1 = Start-Process -FilePath $dVteamExe -ArgumentList @("-addr", $addr1, "-root", "`"$dirtyWork`"", "-security", "`"$dirtySec`"") -WorkingDirectory $dirtyInstall -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  $st1 = Wait-VteamReady $daemon1 $url1 "DirtyInst#1"
  if (-not $st1.canary_ok -or $st1.daemon_health -ne "healthy") { throw "DirtyInst#1 unhealthy: $($st1 | ConvertTo-Json -Compress)" }

  $projName = "脏环境项目 中文空格"; $encProj = [uri]::EscapeDataString($projName)
  Invoke-FormPost "$url1/projects" $url1 @{ name = $projName } | Out-Null
  $projDb = Join-Path $dirtyWork "$projName\state.db"
  if (-not (Test-Path -LiteralPath $projDb) -or (Get-Item -LiteralPath $projDb).Length -eq 0) { throw "Missing state.db under dirty path" }

  $bakZip = Join-Path $dirtyTemp "dirty-vacuum-backup.zip"
  & curl.exe -sS -f -o $bakZip "${url1}/projects/${encProj}/export-backup"
  if ($LASTEXITCODE -ne 0 -or (Get-Item -LiteralPath $bakZip).Length -lt 100) { throw "VACUUM INTO export-backup failed under dirty path" }
  Stop-ProcessTree $daemon1.Id; $daemon1.WaitForExit(5000) | Out-Null; $daemon1 = $null

  # Start real authenticating HTTP/CONNECT tunneling proxy BEFORE launching $daemon2 so $daemon2 inherits mixed-case proxy env!
  $proxyPort = Get-FreeLoopbackPort
  Remove-Item -LiteralPath $proxyHitLog, $proxyStopFlag -Force -ErrorAction SilentlyContinue
  $proxyJob = Start-Job -ArgumentList $proxyPort, $proxyB64, $proxyHitLog, $proxyStopFlag -ScriptBlock {
    param($port, $expectedB64, $hitLog, $stopFlag)
    $tcp = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port); $tcp.Start()
    $enc = [System.Text.UTF8Encoding]::new($false)
    try {
      while (-not (Test-Path -LiteralPath $stopFlag)) {
        if (-not $tcp.Pending()) { Start-Sleep -Milliseconds 100; continue }
        $client = $tcp.AcceptTcpClient()
        try {
          $stream = $client.GetStream(); $stream.ReadTimeout = 5000
          $buf = New-Object byte[] 8192; $n = $stream.Read($buf, 0, $buf.Length)
          if ($n -le 0) { $client.Close(); continue }
          $req = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
          $firstLine = ($req -split "`r`n")[0]
          $authed = $req -match ("(?mi)^Proxy-Authorization:\s*Basic\s+" + [regex]::Escape($expectedB64) + "\s*$")
          [System.IO.File]::AppendAllText($hitLog, ("{0}|{1}`n" -f $authed, $firstLine), $enc)
          if (-not $authed) {
            $rb = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 407 Proxy Authentication Required`r`nProxy-Authenticate: Basic realm=`"vt`"`r`nContent-Length: 0`r`nConnection: close`r`n`r`n")
            $stream.Write($rb, 0, $rb.Length); $stream.Flush()
          } elseif ($firstLine -match '^CONNECT\s+([^:\s]+):(\d+)\s+HTTP/') {
            $up = [System.Net.Sockets.TcpClient]::new(); $up.Connect($Matches[1], [int]$Matches[2])
            try {
              $okB = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 Connection Established`r`n`r`n")
              $stream.Write($okB, 0, $okB.Length); $stream.Flush()
              $upS = $up.GetStream()
              [System.Threading.Tasks.Task]::WaitAny(@($stream.CopyToAsync($upS), $upS.CopyToAsync($stream)), 8000) | Out-Null
            } finally { try { $up.Close() } catch {} }
          } else {
            $rb = [System.Text.Encoding]::ASCII.GetBytes("HTTP/1.1 200 OK`r`nContent-Length: 2`r`nConnection: close`r`n`r`nOK")
            $stream.Write($rb, 0, $rb.Length); $stream.Flush()
          }
        } catch {} finally { try { $client.Close() } catch {} }
      }
    } finally { try { $tcp.Stop() } catch {} }
  }
  Start-Sleep -Milliseconds 600

  $authProxyUrl = "http://${proxyUser}:${proxyPass}@127.0.0.1:${proxyPort}"
  $badProxyUrl = "http://${proxyUser}:WrongPass99!@127.0.0.1:${proxyPort}"
  $env:http_proxy = $authProxyUrl; $env:Https_Proxy = $authProxyUrl
  $env:ALL_PROXY = $authProxyUrl; $env:no_proxy = "localhost,127.0.0.1,.direct.invalid"

  $p2 = Get-FreeLoopbackPort; $addr2 = "127.0.0.1:$p2"; $url2 = "http://$addr2"
  $daemon2 = Start-Process -FilePath $dVteamExe -ArgumentList @("-addr", $addr2, "-root", "`"$dirtyWork`"", "-security", "`"$dirtySec`"") -WorkingDirectory $dirtyInstall -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog
  $st2 = Wait-VteamReady $daemon2 $url2 "DirtyInst#2-HotRestart"
  if (-not $st2.canary_ok -or $st2.daemon_health -ne "healthy") { throw "Hot restart unhealthy" }
  $ovHtml = [string](Invoke-WebRequest -Uri "${url2}/projects/${encProj}?view=overview" -UseBasicParsing -TimeoutSec 10).Content
  if ($ovHtml -notmatch [regex]::Escape($projName)) { throw "Hot restart lost Chinese+Space project state" }
  Write-Host "   [PASS] Custom Chinese+Space /DIR install + WAL/VACUUM INTO + hot restart (with inherited proxy env) verified!"

  # 2) Real installed vteam.exe CP936/GBK subprocess path (POST /api/verify-endpoint -> CLI cp936_probe.cmd exit 23)
  Write-Host "==> [Win-Dirty-E2E 2/4] Triggering real vteam.exe CP936/GBK CLI subprocess & verifying strict UTF-8 JSON + zero crash..."
  $hdrs = @{ "Origin" = $url2; "Sec-Fetch-Site" = "same-origin"; "Accept" = "application/json" }
  $cpResp = Invoke-WebRequest -Uri "$url2/api/verify-endpoint" -Method Post -ContentType "application/json; charset=utf-8" -Headers $hdrs -Body '{"spec":"cp936probe/probe"}' -TimeoutSec 25 -UseBasicParsing
  if (-not (Test-Path -LiteralPath $cp936Marker) -or ((Get-Content -LiteralPath $cp936Marker -Raw).Trim() -ne $runId)) {
    throw "vteam.exe did NOT execute CP936 CLI probe script ($cp936Marker missing)"
  }
  $utf8Strict = [System.Text.UTF8Encoding]::new($false, $true)
  $cpRespText = $utf8Strict.GetString($cpResp.RawContentStream.ToArray())
  $cpJson = $cpRespText | ConvertFrom-Json
  if ($cpJson.ok -ne $false -or [string]::IsNullOrWhiteSpace([string]$cpJson.error)) { throw "Unexpected vteam.exe CP936 CLI probe JSON: $cpRespText" }
  $stAfterCp = Invoke-RestMethod -Uri "$url2/api/status" -TimeoutSec 5
  if ($stAfterCp.daemon_health -ne "healthy") { throw "vteam.exe became unhealthy after CP936 subprocess" }
  $cpUfffd = ([regex]::Matches(([string]$cpJson.raw_error + [string]$cpJson.error), [string][char]0xFFFD)).Count
  Write-Host ("   [PASS] Real vteam.exe CP936/GBK subprocess executed (exit=23, valid UTF-8 JSON, daemon=healthy, raw_error_ufffd_count={0})!" -f $cpUfffd)
  if ($cpUfffd -gt 0) { Write-Host ("   [FINDING] Raw CP936 CLI stderr/stdout produced {0} U+FFFD replacement char(s) in vteam/va CLI error summary." -f $cpUfffd) }

  # 3) Real authenticated HTTP/CONNECT proxy: inherited mixed-case env (default) + custom True| auth + 407 False| + vteam loopback bypass + 0 password leak
  Write-Host "==> [Win-Dirty-E2E 3/4] Verifying inherited mixed-case proxy env, True| CONNECT auth, 407 False|, vteam loopback bypass & 0 secret leak..."
  $sysProxyResp = Invoke-RestMethod -Uri "$url2/api/settings/proxy/test" -Method Post -ContentType "application/json; charset=utf-8" -Headers $hdrs -Body '{"mode":"default"}' -TimeoutSec 15
  $hitLines1 = if (Test-Path -LiteralPath $proxyHitLog) { @(Get-Content -LiteralPath $proxyHitLog) } else { @() }
  if (-not ($hitLines1 | Where-Object { $_ -like "True|CONNECT *" })) {
    throw "Inherited mixed-case proxy env (mode=default) did NOT authenticate with local proxy (hits=$($hitLines1 -join '; '), resp=$($sysProxyResp | ConvertTo-Json -Compress))"
  }
  if (-not $sysProxyResp.ok -or $sysProxyResp.stage -ne "ok") { throw "Inherited mixed-case proxy test expected ok=true stage=ok, got: $($sysProxyResp | ConvertTo-Json -Compress)" }

  $saveResp = Invoke-RestMethod -Uri "$url2/settings/proxy" -Method Post -ContentType "application/json; charset=utf-8" -Headers $hdrs -Body (@{ mode = "custom"; proxy_url = $authProxyUrl; no_proxy = "localhost,127.0.0.1,.direct.invalid" } | ConvertTo-Json -Compress) -TimeoutSec 10
  if (-not $saveResp.ok) { throw "POST /settings/proxy custom mode failed: $($saveResp | ConvertTo-Json -Compress)" }

  $goodProxyResp = Invoke-RestMethod -Uri "$url2/api/settings/proxy/test" -Method Post -ContentType "application/json; charset=utf-8" -Headers $hdrs -Body (@{ mode = "custom"; proxy_url = $authProxyUrl; no_proxy = "localhost,127.0.0.1,.direct.invalid" } | ConvertTo-Json -Compress) -TimeoutSec 15
  if (-not $goodProxyResp.ok -or $goodProxyResp.stage -ne "ok") { throw "Valid custom auth proxy probe expected ok=true stage=ok, got: $($goodProxyResp | ConvertTo-Json -Compress)" }

  $badProxyResp = Invoke-RestMethod -Uri "$url2/api/settings/proxy/test" -Method Post -ContentType "application/json; charset=utf-8" -Headers $hdrs -Body (@{ mode = "custom"; proxy_url = $badProxyUrl; no_proxy = "" } | ConvertTo-Json -Compress) -TimeoutSec 15
  if ($badProxyResp.ok -ne $false -or $badProxyResp.stage -ne "proxy_auth") { throw "Wrong-password proxy probe expected ok=false stage=proxy_auth (407), got: $($badProxyResp | ConvertTo-Json -Compress)" }
  $hitLines2 = @(Get-Content -LiteralPath $proxyHitLog)
  $trueHits = @($hitLines2 | Where-Object { $_ -like "True|*" }).Count
  $falseHits = @($hitLines2 | Where-Object { $_ -like "False|*" }).Count
  if ($trueHits -lt 2 -or $falseHits -lt 1) { throw "Proxy auth log mismatch: expected True|>=2 and False|>=1, got True=$trueHits False=$falseHits" }

  # Assert vteam.exe's OWN outbound HTTP client bypasses proxy for loopback (127.0.0.1)
  $hitsBeforeLoop = $hitLines2.Count
  $null = Invoke-RestMethod -Uri "$url2/api/verify-endpoint" -Method Post -ContentType "application/json; charset=utf-8" -Headers $hdrs -Body (@{ name = "loopcheck"; format = "openai"; base_url = "$url2/v1"; key = "sk-loopback-probe"; models = "mock" } | ConvertTo-Json -Compress) -TimeoutSec 10
  $stLocal = Invoke-RestMethod -Uri "$url2/api/status" -TimeoutSec 5
  $hitsAfterLoop = @(Get-Content -LiteralPath $proxyHitLog).Count
  if ($hitsAfterLoop -ne $hitsBeforeLoop) { throw "vteam.exe loopback outbound request was hijacked by proxy (hits $hitsBeforeLoop -> $hitsAfterLoop)" }

  $sysHtml = [string](Invoke-WebRequest -Uri "$url2/settings/system" -UseBasicParsing -TimeoutSec 10).Content
  $leakTargets = @(
    (Get-Content -LiteralPath $dirtySec -Raw -ErrorAction SilentlyContinue),
    ($stLocal | ConvertTo-Json -Depth 6), ($sysProxyResp | ConvertTo-Json -Depth 6),
    ($goodProxyResp | ConvertTo-Json -Depth 6), ($badProxyResp | ConvertTo-Json -Depth 6), $sysHtml,
    (Get-Content -LiteralPath $outLog -Raw -ErrorAction SilentlyContinue), (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue)
  )
  foreach ($txt in $leakTargets) {
    if ($txt -and ($txt.Contains($proxyPass) -or $txt.Contains("WrongPass99!"))) { throw "SECURITY LEAK: plaintext proxy password exposed in security.toml/runtime response/HTML/logs!" }
  }
  Stop-ProcessTree $daemon2.Id; $daemon2.WaitForExit(5000) | Out-Null; $daemon2 = $null
  Write-Host "   [PASS] Auth HTTP/CONNECT proxy verified (True|=$trueHits, False|=$falseHits, vteam loopback bypass=0, 0 password leak incl. security.toml)!"

  # 4) Real ValidTeam.exe PE Icon/Manifest + Runtime ValidTeamMainWindowClass Icon & PerMonitorV2 DPI Gate
  Write-Host "==> [Win-Dirty-E2E 4/4] Verifying ValidTeam.exe PE resources + live desktop window icon (!= IDI_APPLICATION) & PerMonitorV2..."
  $csharp = @'
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
public static class VtShellProbe {
  const uint LOAD_LIBRARY_AS_DATAFILE = 0x00000002;
  const int WM_GETICON = 0x007F, WM_ENDSESSION = 0x0016, GCLP_HICON = -14, GCLP_HICONSM = -34;
  static readonly IntPtr IDI_APPLICATION = new IntPtr(32512), DPI_V2 = new IntPtr(-4);
  [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }
  [StructLayout(LayoutKind.Sequential)] struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }
  delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] static extern IntPtr LoadIconW(IntPtr hInst, IntPtr lpIconName);
  [DllImport("shell32.dll", CharSet=CharSet.Unicode)] static extern uint ExtractIconExW(string file, int idx, IntPtr[] lg, IntPtr[] sm, uint n);
  [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr hIcon);
  [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO info);
  [DllImport("gdi32.dll")] static extern int GetObjectW(IntPtr h, int c, out BITMAP bm);
  [DllImport("gdi32.dll")] static extern int GetBitmapBits(IntPtr hbm, int cb, byte[] bits);
  [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr h);
  [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr LoadLibraryExW(string path, IntPtr hFile, uint flags);
  [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr hMod);
  [DllImport("kernel32.dll")] static extern IntPtr FindResourceW(IntPtr hMod, IntPtr name, IntPtr type);
  [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr hMod, IntPtr hRes);
  [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr hData);
  [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr hMod, IntPtr hRes);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr lParam);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassNameW(IntPtr hWnd, StringBuilder sb, int max);
  [DllImport("user32.dll")] static extern IntPtr SendMessageW(IntPtr hWnd, int msg, IntPtr wp, IntPtr lp);
  [DllImport("user32.dll")] static extern IntPtr GetClassLongPtrW(IntPtr hWnd, int idx);
  [DllImport("user32.dll")] static extern IntPtr GetWindowDpiAwarenessContext(IntPtr hWnd);
  [DllImport("user32.dll")] static extern int GetAwarenessFromDpiAwarenessContext(IntPtr dpiCtx);
  [DllImport("user32.dll")] static extern bool AreDpiAwarenessContextsEqual(IntPtr a, IntPtr b);
  [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint sessionId);
  [DllImport("user32.dll")] static extern bool PostMessageW(IntPtr hWnd, int msg, IntPtr wp, IntPtr lp);
  static string IconHash(IntPtr hIcon) {
    if (hIcon == IntPtr.Zero) return "ZERO";
    ICONINFO ii; if (!GetIconInfo(hIcon, out ii)) return "NOINFO";
    try {
      IntPtr hbm = ii.hbmColor != IntPtr.Zero ? ii.hbmColor : ii.hbmMask;
      BITMAP bm; GetObjectW(hbm, Marshal.SizeOf(typeof(BITMAP)), out bm);
      byte[] raw = new byte[Math.Max(1, bm.bmWidthBytes * bm.bmHeight)];
      GetBitmapBits(hbm, raw.Length, raw);
      using (var sha = SHA256.Create()) { return BitConverter.ToString(sha.ComputeHash(raw)).Replace("-", ""); }
    } finally { if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor); if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask); }
  }
  public static string VerifyPE(string exePath) {
    string defHash = IconHash(LoadIconW(IntPtr.Zero, IDI_APPLICATION));
    var lg = new IntPtr[1]; var sm = new IntPtr[1];
    uint cnt = ExtractIconExW(exePath, 0, lg, sm, 1);
    if (cnt == 0 || lg[0] == IntPtr.Zero || sm[0] == IntPtr.Zero) throw new Exception("ExtractIconExW returned 0 icons");
    try {
      string lgHash = IconHash(lg[0]), smHash = IconHash(sm[0]);
      if (lgHash == defHash || smHash == defHash) throw new Exception("PE icon equals fallback IDI_APPLICATION");
      IntPtr mod = LoadLibraryExW(exePath, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE);
      if (mod == IntPtr.Zero) throw new Exception("LoadLibraryExW failed");
      try {
        IntPtr hr = FindResourceW(mod, new IntPtr(1), new IntPtr(24));
        if (hr == IntPtr.Zero) throw new Exception("Missing RT_MANIFEST (#24) resource");
        uint sz = SizeofResource(mod, hr);
        byte[] mb = new byte[sz]; Marshal.Copy(LockResource(LoadResource(mod, hr)), mb, 0, (int)sz);
        string xml = Encoding.UTF8.GetString(mb);
        if (!xml.Contains("PerMonitorV2") || !xml.Contains("6.0.0.0")) throw new Exception("RT_MANIFEST missing PerMonitorV2 or Common-Controls 6.0.0.0");
      } finally { FreeLibrary(mod); }
      return "PE_OK:" + lgHash.Substring(0, 12);
    } finally { if (lg[0] != IntPtr.Zero) DestroyIcon(lg[0]); if (sm[0] != IntPtr.Zero) DestroyIcon(sm[0]); }
  }
  public static IntPtr FindMainWindow(uint targetPid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid == targetPid) {
        var sb = new StringBuilder(128); GetClassNameW(h, sb, sb.Capacity);
        if (sb.ToString() == "ValidTeamMainWindowClass" || sb.ToString() == "ValidTeamDesktopWnd") { found = h; return false; }
      }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static string VerifyLiveWindowAndClose(IntPtr hwnd) {
    string defHash = IconHash(LoadIconW(IntPtr.Zero, IDI_APPLICATION));
    IntPtr hBig = SendMessageW(hwnd, WM_GETICON, new IntPtr(1), IntPtr.Zero), hSm = SendMessageW(hwnd, WM_GETICON, IntPtr.Zero, IntPtr.Zero);
    IntPtr cBig = GetClassLongPtrW(hwnd, GCLP_HICON), cSm = GetClassLongPtrW(hwnd, GCLP_HICONSM);
    if (hBig == IntPtr.Zero || hSm == IntPtr.Zero || cBig == IntPtr.Zero || cSm == IntPtr.Zero) throw new Exception("Window/class icon handle is zero");
    if (IconHash(hBig) == defHash || IconHash(hSm) == defHash) throw new Exception("Live window icon matches IDI_APPLICATION");
    IntPtr dpiCtx = GetWindowDpiAwarenessContext(hwnd);
    int awareness = GetAwarenessFromDpiAwarenessContext(dpiCtx);
    bool isV2 = AreDpiAwarenessContextsEqual(dpiCtx, DPI_V2), isV1 = AreDpiAwarenessContextsEqual(dpiCtx, new IntPtr(-3));
    uint wPid = 0, sessId = 1; GetWindowThreadProcessId(hwnd, out wPid); ProcessIdToSessionId(wPid, out sessId);
    if (awareness != 2) throw new Exception(string.Format("Window DPI awareness={0} (want PerMonitor=2, ctx=0x{1:X})", awareness, dpiCtx.ToInt64()));
    if (sessId > 0 && !isV2) throw new Exception(string.Format("Interactive session (id={0}) window DPI context is NOT PerMonitorV2 (ctx=0x{1:X})", sessId, dpiCtx.ToInt64()));
    if (!isV2 && !isV1) throw new Exception(string.Format("Window DPI context is neither PerMonitorV2 nor PerMonitor (ctx=0x{0:X})", dpiCtx.ToInt64()));
    PostMessageW(hwnd, WM_ENDSESSION, new IntPtr(1), IntPtr.Zero);
    return string.Format("LIVE_WND_DPI_ICON_OK(sess={0},ctx=0x{1:X},v2={2})", sessId, dpiCtx.ToInt64(), isV2);
  }
}
'@
  if (-not ("VtShellProbe" -as [type])) { Add-Type -TypeDefinition $csharp -Language CSharp }
  $peRes = [VtShellProbe]::VerifyPE($dGuiExe)
  Write-Host "   [PASS] Static PE resource check: $peRes"

  $env:VTEAM_HEADLESS_TEST = "1"
  $guiProc = Start-Process -FilePath $dGuiExe -WorkingDirectory $dirtyInstall -PassThru
  $hwnd = [IntPtr]::Zero
  for ($w = 0; $w -lt 50; $w++) {
    if ($guiProc.HasExited) { throw "ValidTeam.exe exited before window creation (code=$($guiProc.ExitCode))" }
    $hwnd = [VtShellProbe]::FindMainWindow([uint32]$guiProc.Id)
    if ($hwnd -ne [IntPtr]::Zero) { break }
    Start-Sleep -Milliseconds 400
  }
  if ($hwnd -eq [IntPtr]::Zero) { throw "Timed out waiting for ValidTeamMainWindowClass window handle (pid=$($guiProc.Id))" }
  $liveRes = [VtShellProbe]::VerifyLiveWindowAndClose($hwnd)
  if (-not $guiProc.WaitForExit(10000)) { Stop-ProcessTree $guiProc.Id; throw "ValidTeam.exe did not exit cleanly within 10s" }
  $guiProc = $null; Start-Sleep -Milliseconds 800
  $lingering = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($dirtyInstall, [System.StringComparison]::OrdinalIgnoreCase) })
  if ($lingering.Count -gt 0) { foreach ($lp in $lingering) { Stop-ProcessTree ([int]$lp.ProcessId) }; throw "Lingering process from dirty install dir ($($lingering.Count))" }
  Write-Host "   [PASS] $liveRes + clean ValidTeam.exe/vteam.exe teardown verified!"
  Write-Host "   [PASS] WIN_DIRTY_ENV_AND_SHELL_E2E_OK!"
} finally {
  if ($guiProc -and -not $guiProc.HasExited) { Stop-ProcessTree $guiProc.Id; $guiProc.WaitForExit(5000) | Out-Null }
  if ($daemon2 -and -not $daemon2.HasExited) { Stop-ProcessTree $daemon2.Id; $daemon2.WaitForExit(5000) | Out-Null }
  if ($daemon1 -and -not $daemon1.HasExited) { Stop-ProcessTree $daemon1.Id; $daemon1.WaitForExit(5000) | Out-Null }
  if ($proxyJob) {
    try { if ($proxyStopFlag) { Set-Content -LiteralPath $proxyStopFlag -Value "1" -Encoding ASCII -ErrorAction SilentlyContinue } } catch {}
    try { Wait-Job -Job $proxyJob -Timeout 3 -ErrorAction SilentlyContinue | Out-Null } catch {}
    try { Stop-Job $proxyJob -ErrorAction SilentlyContinue; Remove-Job $proxyJob -Force -ErrorAction SilentlyContinue } catch {}
  }
  $uninst = Join-Path $dirtyInstall "unins000.exe"
  if (Test-Path -LiteralPath $uninst) { try { Start-Process -FilePath $uninst -ArgumentList @("/VERYSILENT","/SUPPRESSMSGBOXES","/NORESTART") -Wait -PassThru | Out-Null } catch {} }
  foreach ($k in $envKeys) { [System.Environment]::SetEnvironmentVariable($k, $savedEnv[$k], "Process") }
  Remove-Item -LiteralPath $outLog, $errLog, $proxyHitLog, $proxyStopFlag -Force -ErrorAction SilentlyContinue
  Remove-DirRetry $dirtyRoot 14
  if (Test-Path -LiteralPath $dirtyRoot) { throw "Lingering NTFS file handle prevented removal of dirty env root: $dirtyRoot" }
}
