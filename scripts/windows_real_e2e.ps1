# Windows Real NTFS & SQLite / Legacy Migration / Portable+Subst / Edge Headless UI E2E Verification
# Invoked by .github/workflows/clean-vm-e2e.yml on windows-latest (Zero App Source Code Required)
param(
  [string]$InstallDir = (Join-Path $env:LOCALAPPDATA "Programs\ValidTeam"),
  [string]$DownloadDir = (Join-Path $env:RUNNER_TEMP "vt-win"),
  [string]$PortableDir = "",
  [string]$ReleaseRepo = "",
  [string]$TargetTag = "",
  [switch]$AllowOfflineSkipRealLLM
)
$ErrorActionPreference = "Stop"
function Write-Utf8NoBom([string]$TargetPath, [string]$Text) {
  $p = Split-Path -Parent $TargetPath; if ($p -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
  [System.IO.File]::WriteAllBytes($TargetPath, [System.Text.UTF8Encoding]::new($false).GetBytes($Text))
}
function Get-FreeLoopbackPort {
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0); $l.Start()
  try { return ([System.Net.IPEndPoint]$l.LocalEndpoint).Port } finally { $l.Stop() }
}
function Read-RedactedLog([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return "<empty>" }
  try {
    $fs = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8, $true)
    try { $txt = $sr.ReadToEnd() } finally { $sr.Dispose(); $fs.Dispose() }
    if ([string]::IsNullOrWhiteSpace($txt)) { return "<empty>" }
    if (-not [string]::IsNullOrWhiteSpace($env:VTEAM_TEST_API_KEY)) { $txt = $txt.Replace($env:VTEAM_TEST_API_KEY, "[REDACTED]") }
    return $txt.Trim()
  } catch { return "<unreadable: $($_.Exception.Message)>" }
}
function Wait-VteamReady([System.Diagnostics.Process]$Proc, [string]$BaseURL, [string]$OutLog, [string]$ErrLog, [string]$Label) {
  for ($i = 0; $i -lt 80; $i++) {
    if ($Proc.HasExited) { break }
    try { $resp = Invoke-RestMethod -Uri "$BaseURL/api/status" -Method Get -TimeoutSec 2; if (-not $resp.bootstrapping) { return $resp } } catch {}
    Start-Sleep -Milliseconds 250
  }
  $exitInfo = if ($Proc.HasExited) { "exited early with code $($Proc.ExitCode)" } else { "did not finish bootstrap within 20s" }
  throw "$Label vteam.exe $exitInfo (stdout: $(Read-RedactedLog $OutLog) | stderr: $(Read-RedactedLog $ErrLog))"
}
function Remove-DirectoryWithRetry([string]$DirPath, [int]$MaxAttempts = 10) {
  for ($a = 1; $a -le $MaxAttempts; $a++) {
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    Remove-Item -LiteralPath $DirPath -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path -LiteralPath $DirPath)) { return }
    Start-Sleep -Milliseconds 250
  }
}

function Assert-CreateProject([string]$BaseURL, [string]$RootDir, [string]$ProjName, [string]$Tag) {
  $enc = [uri]::EscapeDataString($ProjName)
  $hdrFile = Join-Path $env:RUNNER_TEMP "win-e2e-$Tag-hdr.txt"
  $respFile = Join-Path $env:RUNNER_TEMP "win-e2e-$Tag-resp.html"
  try {
    curl.exe -fsS -D "$hdrFile" -o "$respFile" -X POST "$BaseURL/projects" -d "name=$enc"
    if ($LASTEXITCODE -ne 0) { throw "POST /projects ($ProjName) failed via curl.exe (exit=$LASTEXITCODE)" }
    $hdrRaw = Get-Content -LiteralPath $hdrFile -Raw
    if ($hdrRaw -notmatch "(?m)^HTTP/\S+[ \t]+303\b" -or $hdrRaw -notmatch "(?mi)^Location:[ \t]*/projects/\S+") {
      throw "POST /projects ($ProjName) did not return 303 redirect (headers: $hdrRaw)"
    }
  } finally {
    Remove-Item -LiteralPath $hdrFile, $respFile -Force -ErrorAction SilentlyContinue
  }
  $projDir = Join-Path $RootDir $ProjName
  $stateDB = Join-Path $projDir "state.db"
  $healthyMarker = Join-Path $projDir ".statedb_healthy.json"
  if (-not (Test-Path -LiteralPath $stateDB) -or (Get-Item -LiteralPath $stateDB).Length -eq 0) {
    throw "state.db was not created at $stateDB"
  }
  if (-not (Test-Path -LiteralPath $healthyMarker)) {
    throw ".statedb_healthy.json was not written at $healthyMarker"
  }
  return $projDir
}

function Assert-ZipExport([string]$Url, [string]$OutZip, [string]$Label) {
  curl.exe -fsS -o "$OutZip" "$Url"
  if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $OutZip) -or (Get-Item -LiteralPath $OutZip).Length -lt 100) {
    throw "$Label .zip export is empty or missing ($Url)"
  }
  return (Get-Item -LiteralPath $OutZip).Length
}

function Find-UsablePython {
  foreach ($cand in @("python", "py", "python3")) {
    $cmd = Get-Command $cand -ErrorAction SilentlyContinue
    if ($cmd -and ($cmd.Source -notlike "*WindowsApps*")) {
      return $cmd.Source
    }
  }
  throw "No usable Python interpreter found for Clean-VM OTA HTTP gate & SQLite integrity verification"
}

function Invoke-CleanPy([string]$PyExe, [string[]]$PyArgs) {
  if ([System.IO.Path]::GetFileNameWithoutExtension($PyExe) -eq "py") {
    $fullArgs = @("-3") + $PyArgs
    return & $PyExe @fullArgs
  }
  return & $PyExe @PyArgs
}

function Stop-CleanWinOTAProcesses {
  foreach ($n in @("ValidTeam", "vteam")) {
    Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  }
  Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "vt-updater-*" } | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 600
}

function Invoke-CleanWinCliCapture([string]$ExePath, [string[]]$CliArgs, [string]$Tag) {
  $oFile = Join-Path $env:RUNNER_TEMP "vt-clean-cli-$Tag.out.txt"
  $eFile = Join-Path $env:RUNNER_TEMP "vt-clean-cli-$Tag.err.txt"
  Remove-Item -LiteralPath $oFile, $eFile -Force -ErrorAction SilentlyContinue
  $p = Start-Process -FilePath $ExePath -ArgumentList $CliArgs -PassThru -RedirectStandardOutput $oFile -RedirectStandardError $eFile
  if (-not $p.WaitForExit(30000)) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    throw "CLI timed out: $ExePath $($CliArgs -join ' ')"
  }
  $p.WaitForExit()
  return [pscustomobject]@{
    ExitCode = $p.ExitCode
    Stdout   = [string](Get-Content -LiteralPath $oFile -Raw -ErrorAction SilentlyContinue)
  }
}

function Test-SemverAtLeast([string]$Ver, [int]$Major, [int]$Minor, [int]$Patch) {
  $core = ($Ver.Trim().TrimStart("v", "V") -split "[-+]")[0]
  $nums = @([regex]::Matches($core, "\d+") | ForEach-Object { [int]$_.Value })
  while ($nums.Count -lt 3) { $nums += 0 }
  if ($nums[0] -ne $Major) { return $nums[0] -gt $Major }
  if ($nums[1] -ne $Minor) { return $nums[1] -gt $Minor }
  return $nums[2] -ge $Patch
}

function Wait-CleanOtaStatus([string]$ExpectedVer, [string]$ExpectedBuild = "", [int]$TimeoutSec = 45) {
  $dl = (Get-Date).AddSeconds($TimeoutSec)
  while ((Get-Date) -lt $dl) {
    try {
      $st = Invoke-RestMethod -Uri "http://127.0.0.1:8787/api/status" -TimeoutSec 2
      $v = ([string]$st.version).TrimStart("v", "V").Trim()
      $b = ([string]$st.build).Trim()
      if (($st.ok -eq $true) -and (-not $st.bootstrapping) -and ($v -eq $ExpectedVer) -and ([string]::IsNullOrEmpty($ExpectedBuild) -or ($b -eq $ExpectedBuild))) {
        return $st
      }
    } catch {}
    Start-Sleep -Milliseconds 400
  }
  return $null
}

if (-not [string]::IsNullOrWhiteSpace($ReleaseRepo) -and -not [string]::IsNullOrWhiteSpace($TargetTag)) {
  Write-Host "==> [Win-E2E 0/6] Real Clean-VM Live OTA Upgrade (PREV_TAG != $TargetTag -> $TargetTag)..."
  $targetManifestPath = Join-Path $DownloadDir "latest-windows.json"
  $targetZipPath = Join-Path $DownloadDir "ValidTeam-windows-amd64.zip"
  $targetSetupPath = Join-Path $DownloadDir "ValidTeam-Setup.exe"
  if (-not (Test-Path -LiteralPath $targetManifestPath) -or -not (Test-Path -LiteralPath $targetZipPath)) {
    throw "Missing target release assets under $DownloadDir"
  }
  $tManifest = Get-Content -LiteralPath $targetManifestPath -Raw | ConvertFrom-Json
  $targetVer = ([string]$tManifest.version).TrimStart("v", "V").Trim()
  $targetBuild = ([string]$tManifest.build).Trim()
  $resolvedTargetTag = if ($TargetTag -eq "latest") { "v$targetVer" } else { $TargetTag.Trim() }

  $relListRaw = & gh release list -R $ReleaseRepo --exclude-drafts --exclude-pre-releases --limit 20 --json tagName | Out-String
  if ($LASTEXITCODE -ne 0) { throw "gh release list failed for $ReleaseRepo" }
  $relItems = @($relListRaw | ConvertFrom-Json)
  $prevTagObj = $relItems | Where-Object { ([string]$_.tagName).Trim() -ne "" -and ([string]$_.tagName).Trim() -ne $resolvedTargetTag } | Select-Object -First 1
  if (-not $prevTagObj) {
    throw "No previous stable release found with tagName != $resolvedTargetTag in $ReleaseRepo"
  }
  $prevTag = ([string]$prevTagObj.tagName).Trim()
  $prevVer = $prevTag.TrimStart("v", "V")
  $isPrevGte130 = Test-SemverAtLeast $prevVer 1 3 0
  Write-Host "    Resolved PREV_TAG=$prevTag -> TARGET_TAG=$resolvedTargetTag (v$targetVer, build=$targetBuild, prev>=1.3.0=$isPrevGte130)"

  $otaWork = Join-Path $env:RUNNER_TEMP ("vt-win-clean-ota-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
  $prevDlDir = Join-Path $otaWork "prev-dl"
  $prevAppRoot = Join-Path $otaWork "prev-app-中文"
  $otaSrvDir = Join-Path $otaWork "srv"
  $otaCacheDir = Join-Path $otaWork "cache"
  $gateScript = Join-Path $otaSrvDir "ota_gate.py"
  $gateFlag = Join-Path $otaSrvDir "allow_ota.flag"
  $hitLog = Join-Path $otaSrvDir "hits.log"
  $vtDataRoot = Join-Path $env:LOCALAPPDATA "ValidTeam"
  $otaSecToml = Join-Path $vtDataRoot "security.toml"
  $otaProjName = "OTA保留验证"
  $otaProjEnc = [uri]::EscapeDataString($otaProjName)
  $otaProjDir = Join-Path (Join-Path $vtDataRoot "Projects") $otaProjName
  $otaProjToml = Join-Path $otaProjDir "project.toml"
  $otaProjDb = Join-Path $otaProjDir "state.db"

  $pyExe = Find-UsablePython
  $script:cleanOtaHttp = $null
  $hadPreExistingSecToml = Test-Path -LiteralPath $otaSecToml
  $savedM = $env:VTEAM_WIN_OTA_MANIFEST_URL
  $savedA = $env:VTEAM_WIN_OTA_AUTO_CONFIRM
  $savedH = $env:VTEAM_HEADLESS_TEST
  $savedC = $env:VTEAM_WIN_OTA_CACHE_DIR
  $savedB = $env:VALID_TEAM_SECRET_BACKEND

  try {
    Stop-CleanWinOTAProcesses
    New-Item -ItemType Directory -Force -Path $prevDlDir, $prevAppRoot, $otaSrvDir, $otaCacheDir, $vtDataRoot | Out-Null
    & gh release download $prevTag -R $ReleaseRepo -p "ValidTeam-windows-amd64.zip" -D $prevDlDir --clobber
    if ($LASTEXITCODE -ne 0) { throw "Failed to download $prevTag ValidTeam-windows-amd64.zip" }
    Expand-Archive -LiteralPath (Join-Path $prevDlDir "ValidTeam-windows-amd64.zip") -DestinationPath $prevAppRoot -Force
    $prevGuiExe = (Get-ChildItem -Path $prevAppRoot -Filter "ValidTeam.exe" -Recurse | Select-Object -First 1).FullName
    if (-not $prevGuiExe) { throw "Missing ValidTeam.exe in $prevTag archive" }
    $prevInstallDir = Split-Path -Parent $prevGuiExe
    $prevVteamExe = Join-Path $prevInstallDir "vteam.exe"

    Copy-Item -LiteralPath $targetZipPath -Destination (Join-Path $otaSrvDir "ValidTeam-windows-amd64.zip") -Force
    Copy-Item -LiteralPath $targetZipPath -Destination (Join-Path $otaSrvDir "tampered-windows-amd64.zip") -Force
    if (Test-Path -LiteralPath $targetSetupPath) {
      Copy-Item -LiteralPath $targetSetupPath -Destination (Join-Path $otaSrvDir "ValidTeam-Setup.exe") -Force
      Copy-Item -LiteralPath $targetSetupPath -Destination (Join-Path $otaSrvDir "tampered-Setup.exe") -Force
    }
    $flipCode = 'import sys; p=sys.argv[1]; f=open(p,"r+b"); f.seek(-1,2); b=f.read(1); f.seek(-1,2); f.write(bytes([b[0]^0xFF])); f.close()'
    Invoke-CleanPy $pyExe @("-c", $flipCode, (Join-Path $otaSrvDir "tampered-windows-amd64.zip")) | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Failed to tamper bad zip" }

    $otaPort = Get-FreeLoopbackPort
    $goodM = $tManifest | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $goodM.zip_url = "http://127.0.0.1:$otaPort/ValidTeam-windows-amd64.zip"
    $goodM.setup_url = "http://127.0.0.1:$otaPort/ValidTeam-Setup.exe"
    Write-Utf8NoBom (Join-Path $otaSrvDir "latest-windows.json") (($goodM | ConvertTo-Json -Depth 4) + "`n")
    $badM = $goodM | ConvertTo-Json -Depth 4 | ConvertFrom-Json
    $badM.zip_url = "http://127.0.0.1:$otaPort/tampered-windows-amd64.zip"
    $badM.setup_url = "http://127.0.0.1:$otaPort/tampered-Setup.exe"
    Write-Utf8NoBom (Join-Path $otaSrvDir "bad-latest-windows.json") (($badM | ConvertTo-Json -Depth 4) + "`n")

    $gateCode = @'
import argparse, http.server, os, socketserver, time
p = argparse.ArgumentParser()
p.add_argument("--dir", required=True); p.add_argument("--port", type=int, required=True)
p.add_argument("--mode", required=True); p.add_argument("--flag", required=True)
p.add_argument("--hit-log", required=True)
a = p.parse_args()
def log(m):
    with open(a.hit_log, "a", encoding="utf-8") as f: f.write(m + "\n"); f.flush()
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *x, **kw): super().__init__(*x, directory=a.dir, **kw)
    def log_message(self, *x): pass
    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/latest-windows.json" and a.mode == "gated":
            log("MANIFEST_WAITING")
            dl = time.monotonic() + 25.0
            while not os.path.exists(a.flag):
                if time.monotonic() >= dl: self.send_error(503); return
                time.sleep(0.05)
            log("MANIFEST_RELEASED")
        elif path == "/tampered-windows-amd64.zip": log("BAD_ASSET_SERVED")
        elif path == "/ValidTeam-windows-amd64.zip": log("GOOD_ASSET_SERVED")
        super().do_GET()
class S(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True; daemon_threads = True
S(("127.0.0.1", a.port), H).serve_forever()
'@
    Write-Utf8NoBom $gateScript $gateCode

    $secPlaceholder = "default_model = `"selftest/mock`"`n`n[[api]]`nname = `"selftest`"`nformat = `"openai`"`nbase_url = `"http://127.0.0.1:9/v1`"`nkey = `"sk-ci-unit-test-placeholder`"`nmodels = [`"mock`"]`n"
    Write-Utf8NoBom $otaSecToml $secPlaceholder
    $secHashPre = (Get-FileHash -LiteralPath $otaSecToml -Algorithm SHA256).Hash
    if (Test-Path -LiteralPath $otaProjDir) { Remove-Item -LiteralPath $otaProjDir -Recurse -Force }

    $startGate = {
      param([string]$mode)
      if ($script:cleanOtaHttp -and -not $script:cleanOtaHttp.HasExited) {
        Stop-Process -Id $script:cleanOtaHttp.Id -Force -ErrorAction SilentlyContinue
        $script:cleanOtaHttp.WaitForExit(3000) | Out-Null
      }
      Write-Utf8NoBom $hitLog ""
      $pref = if ([System.IO.Path]::GetFileNameWithoutExtension($pyExe) -eq "py") { "-3 " } else { "" }
      $psi = [System.Diagnostics.ProcessStartInfo]::new()
      $psi.FileName = $pyExe
      $psi.Arguments = "${pref}`"$gateScript`" --dir `"$otaSrvDir`" --port $otaPort --mode $mode --flag `"$gateFlag`" --hit-log `"$hitLog`""
      $psi.WorkingDirectory = $otaSrvDir; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
      $script:cleanOtaHttp = [System.Diagnostics.Process]::Start($psi)
      for ($i = 0; $i -lt 30; $i++) {
        try { if ((Invoke-WebRequest -Uri "http://127.0.0.1:$otaPort/bad-latest-windows.json" -TimeoutSec 2 -UseBasicParsing).StatusCode -eq 200) { return } } catch {}
        Start-Sleep -Milliseconds 150
      }
      throw "Clean-VM OTA HTTP gate failed to start"
    }

    # Phase 1: Negative tampered rejection + seed OTA保留验证 project
    & $startGate "bad"
    $env:VALID_TEAM_SECRET_BACKEND = "memory"
    $env:VTEAM_WIN_OTA_CACHE_DIR = $otaCacheDir
    $env:VTEAM_WIN_OTA_MANIFEST_URL = "http://127.0.0.1:$otaPort/bad-latest-windows.json"
    $env:VTEAM_WIN_OTA_AUTO_CONFIRM = "1"
    $env:VTEAM_HEADLESS_TEST = "1"

    $g1 = Start-Process -FilePath $prevGuiExe -WorkingDirectory $prevInstallDir -PassThru
    if (-not (Wait-CleanOtaStatus -ExpectedVer $prevVer -TimeoutSec 45)) { throw "Clean-VM OTA Phase 1 $prevTag failed to come online" }
    $d1 = Get-Process -Name "vteam" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d1) { throw "Clean-VM OTA Phase 1 missing vteam.exe" }

    $otaHdr = Join-Path $otaWork "proj.hdr"
    curl.exe -fsS -D "$otaHdr" -o NUL -X POST "http://127.0.0.1:8787/projects" -d "name=$otaProjEnc"
    if ($LASTEXITCODE -ne 0 -or ((Get-Content -LiteralPath $otaHdr -Raw) -notmatch "(?m)^HTTP/\S+[ \t]+303\b")) {
      throw "Clean-VM OTA Phase 1 failed to create $otaProjName project"
    }
    if (-not (Test-Path -LiteralPath $otaProjToml) -or -not (Test-Path -LiteralPath $otaProjDb)) {
      throw "Clean-VM OTA Phase 1 missing $otaProjToml or $otaProjDb"
    }
    $projHashPre = (Get-FileHash -LiteralPath $otaProjToml -Algorithm SHA256).Hash

    $errLog = Join-Path $otaCacheDir "last-update-error.log"
    $rejOk = $false
    if ($isPrevGte130) {
      for ($i = 0; $i -lt 60; $i++) {
        $hTxt = Get-Content -LiteralPath $hitLog -Raw -ErrorAction SilentlyContinue
        if ($hTxt -match "BAD_ASSET_SERVED" -and (Test-Path -LiteralPath $errLog) -and ((Get-Item -LiteralPath $errLog).Length -gt 0)) { $rejOk = $true; break }
        Start-Sleep -Milliseconds 500
      }
      if (-not $rejOk) { throw "Clean-VM OTA Phase 1 did not record tampered rejection (BAD_ASSET_SERVED + last-update-error.log)" }
    } else {
      Write-Host "    [TRANSITION-v1.3.0] Previous stable $prevTag (< v1.3.0) predates stage-failure last-update-error.log; verifying live tampered rejection & zero staged artifacts..."
      for ($i = 0; $i -lt 60; $i++) {
        $hTxt = Get-Content -LiteralPath $hitLog -Raw -ErrorAction SilentlyContinue
        if ($hTxt -match "BAD_ASSET_SERVED") { $rejOk = $true; break }
        Start-Sleep -Milliseconds 500
      }
      if (-not $rejOk) { throw "Clean-VM OTA Phase 1 did not observe BAD_ASSET_SERVED for $prevTag" }
      Start-Sleep -Seconds 4
    }
    if (Get-ChildItem -Path $otaCacheDir -Filter "*.part" -Recurse -ErrorAction SilentlyContinue) { throw "Clean-VM OTA Phase 1 left .part files" }
    $badStageFiles = Get-ChildItem -Path $otaCacheDir -Include "ready.json", "last-applied.json", "vt-updater-*.exe" -Recurse -ErrorAction SilentlyContinue
    if ($badStageFiles) { throw "Clean-VM OTA Phase 1 left staged/updater artifacts after tampered rejection: $($badStageFiles.FullName -join ', ')" }
    $badUpdProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "vt-updater-*" }
    if ($badUpdProcs) { throw "Clean-VM OTA Phase 1 unexpectedly spawned vt-updater-* after tampered rejection" }
    if (-not (Get-Process -Id $g1.Id -ErrorAction SilentlyContinue) -or -not (Get-Process -Id $d1.Id -ErrorAction SilentlyContinue)) {
      throw "Clean-VM OTA Phase 1 baseline PIDs died after rejection"
    }
    if (-not (Wait-CleanOtaStatus -ExpectedVer $prevVer -TimeoutSec 5)) {
      throw "Clean-VM OTA Phase 1 /api/status drifted from v$prevVer after tampered rejection"
    }
    Stop-CleanWinOTAProcesses

    # Phase 2: Gated positive PREV_TAG -> TARGET_TAG transition + 4 hard assertions
    Remove-Item -LiteralPath $gateFlag, $errLog -Force -ErrorAction SilentlyContinue
    & $startGate "gated"
    $env:VTEAM_WIN_OTA_MANIFEST_URL = "http://127.0.0.1:$otaPort/latest-windows.json"
    $g2 = Start-Process -FilePath $prevGuiExe -WorkingDirectory $prevInstallDir -PassThru
    if (-not (Wait-CleanOtaStatus -ExpectedVer $prevVer -TimeoutSec 45)) { throw "Clean-VM OTA Phase 2 $prevTag failed to come online" }
    $d2 = Get-Process -Name "vteam" -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $d2) { throw "Clean-VM OTA Phase 2 missing baseline vteam.exe" }
    $oldG = $g2.Id; $oldD = $d2.Id
    Write-Utf8NoBom $gateFlag "go`n"

    if (-not (Wait-CleanOtaStatus -ExpectedVer $targetVer -ExpectedBuild $targetBuild -TimeoutSec 90)) {
      throw "Clean-VM OTA Phase 2 did not upgrade /api/status to v$targetVer ($targetBuild) within 90s"
    }
    $gVer = Invoke-CleanWinCliCapture $prevGuiExe @("--version") "clean-gui-after"
    $vVer = Invoke-CleanWinCliCapture $prevVteamExe @("--version") "clean-vteam-after"
    if ($gVer.ExitCode -ne 0 -or $gVer.Stdout -notmatch [regex]::Escape("v$targetVer")) { throw "Clean-VM OTA Assertion 1 failed: ValidTeam.exe=$($gVer.Stdout)" }
    if ($vVer.ExitCode -ne 0 -or $vVer.Stdout -notmatch [regex]::Escape("v$targetVer")) { throw "Clean-VM OTA Assertion 1 failed: vteam.exe=$($vVer.Stdout)" }
    if ((Get-ChildItem -Path $prevInstallDir -Filter "*.old" -ErrorAction SilentlyContinue) -or (Get-ChildItem -Path $otaCacheDir -Filter "*.part" -Recurse -ErrorAction SilentlyContinue)) {
      throw "Clean-VM OTA Assertion 1 failed: leftover .old/.part files"
    }

    for ($w = 0; $w -lt 20; $w++) {
      if (-not (Get-Process -Id $oldG -ErrorAction SilentlyContinue) -and -not (Get-Process -Id $oldD -ErrorAction SilentlyContinue)) { break }
      Start-Sleep -Milliseconds 300
    }
    if ((Get-Process -Id $oldG -ErrorAction SilentlyContinue) -or (Get-Process -Id $oldD -ErrorAction SilentlyContinue)) {
      throw "Clean-VM OTA Assertion 3 failed: old PIDs survived ($oldG / $oldD)"
    }
    $newDs = @(Get-Process -Name "vteam" -ErrorAction SilentlyContinue)
    $newGs = @(Get-Process -Name "ValidTeam" -ErrorAction SilentlyContinue)
    if ($newDs.Count -ne 1 -or $newDs[0].Id -eq $oldD -or ($newGs | Where-Object { $_.Id -ne $oldG }).Count -lt 1) {
      throw "Clean-VM OTA Assertion 2/3 failed: invalid upgraded process state"
    }
    if ((Get-FileHash -LiteralPath $otaSecToml -Algorithm SHA256).Hash -ne $secHashPre) { throw "Clean-VM OTA Assertion 4 failed: security.toml altered" }
    if ((Get-FileHash -LiteralPath $otaProjToml -Algorithm SHA256).Hash -ne $projHashPre) { throw "Clean-VM OTA Assertion 4 failed: project.toml altered" }
    if ((curl.exe -sS -o NUL -w "%{http_code}" "http://127.0.0.1:8787/projects/$otaProjEnc").Trim() -ne "200") {
      throw "Clean-VM OTA Assertion 4 failed: GET /projects/$otaProjEnc != 200"
    }
    $sqlCode = 'import sqlite3, sys; c=sqlite3.connect(sys.argv[1], timeout=15); c.execute("PRAGMA busy_timeout=15000"); r=c.execute("PRAGMA integrity_check").fetchone()[0]; c.close(); print(r); sys.exit(0 if r=="ok" else 1)'
    $sqlRes = (Invoke-CleanPy $pyExe @("-c", $sqlCode, $otaProjDb) | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $sqlRes -ne "ok") { throw "Clean-VM OTA Assertion 4 failed: sqlite integrity_check='$sqlRes'" }

    Write-Host "WIN_CLEAN_OTA_E2E_OK from=$prevTag to=$targetVer"
  } finally {
    Stop-CleanWinOTAProcesses
    if ($script:cleanOtaHttp -and -not $script:cleanOtaHttp.HasExited) { Stop-Process -Id $script:cleanOtaHttp.Id -Force -ErrorAction SilentlyContinue }
    $env:VTEAM_WIN_OTA_MANIFEST_URL = $savedM
    $env:VTEAM_WIN_OTA_AUTO_CONFIRM = $savedA
    $env:VTEAM_HEADLESS_TEST = $savedH
    $env:VTEAM_WIN_OTA_CACHE_DIR = $savedC
    $env:VALID_TEAM_SECRET_BACKEND = $savedB
    if (-not $hadPreExistingSecToml) {
      Remove-Item -LiteralPath $otaSecToml -Force -ErrorAction SilentlyContinue
    }
    Remove-DirectoryWithRetry $otaProjDir 8
    Remove-DirectoryWithRetry $otaWork 8
  }
}

Write-Host "==> [Win-E2E 1/6] Running stripped native Windows Go unit test binaries..."
$requireWinTestBins = ($env:VTEAM_REQUIRE_WIN_TEST_BINS -eq "1") -or (@(Get-ChildItem -Path $DownloadDir -Filter "*.test.exe" -ErrorAction SilentlyContinue).Count -gt 0)
foreach ($testBin in @("core-platform.test.exe", "vteam-statedb.test.exe", "windows-app.test.exe", "va-sdk.test.exe", "va-llm.test.exe")) {
  $binPath = Join-Path $DownloadDir $testBin
  if (Test-Path -LiteralPath $binPath) {
    if ((Get-Item -LiteralPath $binPath).Length -le 0) {
      throw "Required native Windows unit test binary is empty (0 bytes): $binPath"
    }
    Write-Host "   -> Executing $testBin on real Windows NTFS (clean empty workdir)..."
    $tWork = Join-Path $env:RUNNER_TEMP ("ut-" + $testBin)
    if (Test-Path -LiteralPath $tWork) { Remove-Item -LiteralPath $tWork -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $tWork | Out-Null
    Push-Location $tWork
    try {
      $testArgs = @("-test.short")
      if ($testBin -eq "va-llm.test.exe") {
        # Source-only static *.go scan already verified in private-repo full gate;
        # public Clean VM intentionally runs with zero private Go source files.
        $testArgs += "-test.skip=^TestCLISyncNoStaleLegacyConstantsInProductionSource$"
      }
      & $binPath @testArgs
      if ($LASTEXITCODE -ne 0) { throw "Native Windows unit test binary $testBin failed with exit code $LASTEXITCODE" }
      Write-Host "   [PASS] $testBin passed on real Windows NTFS!"
    } finally {
      Pop-Location
      Remove-Item -LiteralPath $tWork -Recurse -Force -ErrorAction SilentlyContinue
    }
  } elseif ($requireWinTestBins) {
    throw "Required native Windows unit test binary missing: $binPath"
  }
}

$vteamExe = Join-Path $InstallDir "vteam.exe"
$vaExe = Join-Path $InstallDir "va.exe"
if (-not (Test-Path -LiteralPath $vteamExe)) { throw "Missing $vteamExe" }
if (-not (Test-Path -LiteralPath $vaExe)) { throw "Missing $vaExe" }

$e2eRoot = Join-Path $env:RUNNER_TEMP "Valid Team 中文工作区 #1"
if (Test-Path -LiteralPath $e2eRoot) { Remove-Item -LiteralPath $e2eRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $e2eRoot | Out-Null

# Pre-seed v1.2.11 pure-Markdown legacy project (no opening.json, no state.db)
$legacyName = "legacy-v1211-中文"
$legacyEnc = [uri]::EscapeDataString($legacyName)
$legacyDir = Join-Path $e2eRoot $legacyName
Write-Utf8NoBom (Join-Path $legacyDir "project.toml") ("name = `"旧版升级项目`"`nwork_start = `"09:00`"`nwork_end = `"18:30`"`n")
Write-Utf8NoBom (Join-Path $legacyDir "NOTES.md") "# 旧版笔记`n"
Write-Utf8NoBom (Join-Path $legacyDir "roles\system\ROLE.md") "# 总办职责`n"
Write-Utf8NoBom (Join-Path $legacyDir "directives\20261101T100000-leg01.md") (@(
  'id: 20261101T100000-leg01', 'from: boss', 'to: system', 'subject: 历史冷迁移任务',
  'kind: task', 'status: done', 'created_at: 2026-11-01T10:00:00Z', 'finished_at: 2026-11-01T10:05:00Z',
  '---', '历史冷迁移正文', '---result---', '历史冷迁移已完成', ''
) -join "`n")

$port = Get-FreeLoopbackPort
$addr = "127.0.0.1:$port"
$baseURL = "http://$addr"
$secFile = Join-Path $e2eRoot "security.toml"
$secToml = "default_model = `"selftest/mock`"`n`n[[api]]`nname = `"selftest`"`nformat = `"openai`"`nbase_url = `"http://127.0.0.1:9/v1`"`nkey = `"sk-selftest-placeholder`"`nmodels = [`"mock`"]`n"
[System.IO.File]::WriteAllBytes($secFile, [System.Text.Encoding]::ASCII.GetBytes($secToml))

$outLog = Join-Path $env:RUNNER_TEMP "win-e2e-vteam-out.log"
$errLog = Join-Path $env:RUNNER_TEMP "win-e2e-vteam-err.log"
$portOutLog = Join-Path $env:RUNNER_TEMP "win-e2e-portable-out.log"
$portErrLog = Join-Path $env:RUNNER_TEMP "win-e2e-portable-err.log"
Remove-Item -LiteralPath $outLog, $errLog, $portOutLog, $portErrLog -Force -ErrorAction SilentlyContinue

$daemon = $null
$portDaemon = $null
$edgeProc = $null
$cdpSocket = $null
$edgeUserDataDir = Join-Path $env:RUNNER_TEMP "vt-edge-profile"
$substDrv = $null
$substMounted = $false
$substBacking = Join-Path $env:RUNNER_TEMP "vt-subst-backing"
$substRoot = $null
$hadPrimaryError = $false

Write-Host "==> [Win-E2E 2/6] Starting Instance #1 vteam.exe on $baseURL (legacy v1.2.11 cold migration + devil path: $e2eRoot)..."
$daemon = Start-Process -FilePath $vteamExe -ArgumentList @("-addr", $addr, "-root", "`"$e2eRoot`"", "-security", "`"$secFile`"") -WorkingDirectory $InstallDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $outLog -RedirectStandardError $errLog

try {
  $status = Wait-VteamReady $daemon $baseURL $outLog $errLog "Instance#1"
  if (-not $status.canary_ok -or $status.daemon_health -ne "healthy" -or [int]$status.isolated_project_count -ne 0) {
    throw "Instance#1 /api/status unexpected: canary_ok=$($status.canary_ok) health=$($status.daemon_health) isolated=$($status.isolated_project_count) err=$($status.canary_error)"
  }
  $legacyDB = Join-Path $legacyDir "state.db"
  if (-not (Test-Path -LiteralPath $legacyDB) -or (Get-Item -LiteralPath $legacyDB).Length -eq 0 -or -not (Test-Path -LiteralPath (Join-Path $legacyDir ".statedb_healthy.json"))) {
    throw "Legacy cold migration did not materialize state.db + .statedb_healthy.json under $legacyDir"
  }
  Write-Host "   [PASS] /api/status canary_ok=true daemon_health=healthy isolated=0 & v1.2.11 legacy directives/*.md migrated cleanly!"

  Write-Host "==> [Win-E2E 3/6] Testing real SQLite CreateProject, VACUUM INTO .zip backup & ?salvage=1..."
  $projName = "win-team-中文"
  $encProj = [uri]::EscapeDataString($projName)
  $projDir = Assert-CreateProject $baseURL $e2eRoot $projName "inst1"
  Write-Utf8NoBom (Join-Path $projDir "workspace\分析报告\测试专题\summary.md") "# Windows E2E Deliverable`n"

  $zipLen = Assert-ZipExport "${baseURL}/projects/${encProj}/export-backup" (Join-Path $env:RUNNER_TEMP "win-team-backup.zip") "Instance#1 normal"
  $salvLen = Assert-ZipExport "${baseURL}/projects/${encProj}/export-backup?salvage=1" (Join-Path $env:RUNNER_TEMP "win-team-salvage.zip") "Instance#1 salvage"
  Write-Host "   [PASS] Real SQLite state.db + VACUUM INTO & ?salvage=1 export-backup succeeded ($zipLen / $salvLen bytes)"

  if (-not [string]::IsNullOrWhiteSpace($env:VTEAM_TEST_API_KEY)) {
    Write-Host "==> [Win-E2E 3.5/6] VTEAM_TEST_API_KEY present: verifying real POST /setup + va.exe config check..."
    $apiName = if ($env:VTEAM_TEST_API_NAME) { $env:VTEAM_TEST_API_NAME } else { "opencode-go" }
    $apiFmt = if ($env:VTEAM_TEST_API_FORMAT) { $env:VTEAM_TEST_API_FORMAT } else { "openai" }
    $apiBase = if ($env:VTEAM_TEST_API_BASE_URL) { $env:VTEAM_TEST_API_BASE_URL } else { "https://opencode.ai/inference/go/openai/v1" }
    $apiModel = if ($env:VTEAM_TEST_API_MODEL) { $env:VTEAM_TEST_API_MODEL } else { "deepseek-v4.1-flash" }
    $setupHdr = Join-Path $env:RUNNER_TEMP "win-e2e-setup-hdr.txt"
    $setupResp = Join-Path $env:RUNNER_TEMP "win-e2e-setup-resp.html"
    $setupOK = $false
    for ($setupTry = 1; $setupTry -le 4; $setupTry++) {
      Remove-Item -LiteralPath $setupHdr, $setupResp -Force -ErrorAction SilentlyContinue
      curl.exe -sS -D "$setupHdr" -o "$setupResp" -X POST "$baseURL/setup" `
        --data-urlencode "name=$apiName" --data-urlencode "format=$apiFmt" `
        --data-urlencode "base_url=$apiBase" --data-urlencode "key=$($env:VTEAM_TEST_API_KEY)" --data-urlencode "model=$apiModel"
      $hdrTxt = if (Test-Path -LiteralPath $setupHdr) { Get-Content -LiteralPath $setupHdr -Raw } else { "" }
      if ($LASTEXITCODE -eq 0 -and $hdrTxt -match "(?m)^HTTP/\S+[ \t]+303\b" -and $hdrTxt -match "(?mi)^Location:[ \t]*/\r?$") {
        & $vaExe "config" "--security" "$secFile" "check" | Out-Null
        if ($LASTEXITCODE -eq 0) {
          $setupOK = $true
          Write-Host "   [PASS] POST /setup + va.exe config check succeeded on Windows ($apiName/$apiModel, attempt $setupTry)"
          break
        }
      }
      if ($setupTry -lt 4) { Start-Sleep -Seconds ($setupTry * 3) }
    }
    if (-not $setupOK) {
      $safeHdr = if (Test-Path -LiteralPath $setupHdr) { (Get-Content -LiteralPath $setupHdr -Raw).Replace($env:VTEAM_TEST_API_KEY, "[REDACTED]") } else { "<no headers>" }
      throw "POST /setup failed after 4 attempts ($apiName/$apiModel): $safeHdr"
    }
    $realLlmScript = Join-Path $PSScriptRoot "windows_real_llm_e2e.ps1"
    if (-not (Test-Path -LiteralPath $realLlmScript)) { throw "Missing required modular script: $realLlmScript" }
    & $realLlmScript -BaseURL $baseURL -WorkspaceRoot $e2eRoot -InstallDir $InstallDir -Model "$apiName/$apiModel"
  } elseif ($env:CI -eq "true" -or -not $AllowOfflineSkipRealLLM) {
    throw "VTEAM_TEST_API_KEY is required for Windows real-LLM E2E (CI=true forbids silent skip)"
  }

  # Stage 3.8/6: Cross-OS Env & Path Real Windows Assertions (CODEX_HOME Chinese+Space & Non-PATH agy & Zero Unix which/Duplicate Copy)
  Write-Host "==> [Win-E2E 3.8/6] Verifying CODEX_HOME (Chinese+Space, absent ~/.codex), non-PATH agy detection & Windows CLI hint copy..."
  $envE2ERoot = Join-Path $env:RUNNER_TEMP "Valid Team 环境变量验证"
  $envFakeHome = Join-Path $envE2ERoot "fake-home"
  $envCodexHome = Join-Path $envE2ERoot "自定义 codex 目录 中文空格"
  $envNonPathBin = Join-Path $envE2ERoot "非默认PATH工具目录"
  $envWorkRoot = Join-Path $envE2ERoot "ws"
  $envSecFile = Join-Path $envE2ERoot "security.toml"
  $envOutLog = Join-Path $env:RUNNER_TEMP "win-e2e-env-out.log"
  $envErrLog = Join-Path $env:RUNNER_TEMP "win-e2e-env-err.log"
  $envDaemon = $null
  $savedEnvMap = @{}
  $envKeysToSave = @("USERPROFILE", "HOME", "CODEX_HOME", "CODEX_CLI_AUTH_FILE", "XDG_BIN_HOME", "AGY_HOME", "GEMINI_CLI_HOME", "AGY_TOKEN_FILE", "AGY_TOKEN_BLOB", "VALID_TEAM_SECRET_BACKEND", "VTEAM_DISABLE_HOST_ENV_REFRESH")
  foreach ($ek in $envKeysToSave) {
    $savedEnvMap[$ek] = [Environment]::GetEnvironmentVariable($ek, "Process")
  }
  try {
    if (Test-Path -LiteralPath $envE2ERoot) { Remove-DirectoryWithRetry $envE2ERoot 10 }
    New-Item -ItemType Directory -Force -Path $envFakeHome, $envCodexHome, $envNonPathBin, $envWorkRoot | Out-Null
    $defaultCodexInFakeHome = Join-Path $envFakeHome ".codex"
    if (Test-Path -LiteralPath $defaultCodexInFakeHome) { throw "Unexpected default .codex in isolated fake home: $defaultCodexInFakeHome" }

    Write-Utf8NoBom (Join-Path $envCodexHome "auth.json") '{"auth_mode":"chatgpt","tokens":{"access_token":"dummy-win-e2e-codex-token"}}'
    Write-Utf8NoBom (Join-Path $envNonPathBin "codex.cmd") "@echo off`r`nexit /b 0`r`n"
    Write-Utf8NoBom (Join-Path $envNonPathBin "agy.cmd") "@echo off`r`nexit /b 0`r`n"
    Write-Utf8NoBom $envSecFile $secToml

    $env:USERPROFILE = $envFakeHome
    $env:HOME = $envFakeHome
    $env:CODEX_HOME = $envCodexHome
    $env:CODEX_CLI_AUTH_FILE = ""
    $env:XDG_BIN_HOME = $envNonPathBin
    $env:AGY_HOME = ""
    $env:GEMINI_CLI_HOME = ""
    $env:AGY_TOKEN_FILE = ""
    $env:AGY_TOKEN_BLOB = ""
    $env:VALID_TEAM_SECRET_BACKEND = "memory"
    $env:VTEAM_DISABLE_HOST_ENV_REFRESH = "1"

    $envPort = Get-FreeLoopbackPort
    $envAddr = "127.0.0.1:$envPort"
    $envBaseURL = "http://$envAddr"
    Remove-Item -LiteralPath $envOutLog, $envErrLog -Force -ErrorAction SilentlyContinue
    $envDaemon = Start-Process -FilePath $vteamExe -ArgumentList @("-addr", $envAddr, "-root", "`"$envWorkRoot`"", "-security", "`"$envSecFile`"") -WorkingDirectory $InstallDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $envOutLog -RedirectStandardError $envErrLog
    Wait-VteamReady $envDaemon $envBaseURL $envOutLog $envErrLog "Instance#EnvPath" | Out-Null

    $sysHtml1 = Invoke-WebRequest -Uri "${envBaseURL}/settings/system" -UseBasicParsing -TimeoutSec 10
    $setupHtml1 = Invoke-WebRequest -Uri "${envBaseURL}/setup" -UseBasicParsing -TimeoutSec 10
    $sysTxt1 = [string]$sysHtml1.Content
    $setupTxt1 = [string]$setupHtml1.Content

    if ($sysTxt1 -notmatch 'class="cli-tool-row is-ready"[^>]*data-cli-name="codex"') {
      throw "CODEX_HOME Chinese+Space assertion failed: codex was not detected as is-ready when default .codex is absent"
    }
    $agyBlockMatch = [regex]::Match($sysTxt1, '<div class="cli-tool-row[^"]*" data-cli-name="agy">[\s\S]*?</div>\s*</div>')
    if (-not $agyBlockMatch.Success) {
      throw "Non-PATH agy assertion failed: agy row not found on /settings/system"
    }
    if ($agyBlockMatch.Value -match '<span class="tag tag-quiet">未安装</span>') {
      throw "Non-PATH agy assertion failed: agy in XDG_BIN_HOME ($envNonPathBin) was reported as 未安装"
    }
    foreach ($pair in @(@{ name = "/settings/system(with-agy)"; txt = $sysTxt1 }, @{ name = "/setup(with-agy)"; txt = $setupTxt1 })) {
      if ($pair.txt -match 'which\s+agy') { throw "$($pair.name) leaked Unix 'which agy' hint on Windows" }
      if ($pair.txt -match '未安装\s+未安装' -or $pair.txt -match '<span class="cli-tool-status-hint">\s*未安装\s*</span>') {
        throw "$($pair.name) rendered duplicate '未安装 未安装' copy"
      }
    }

    # Remove agy.cmd & trigger refresh_cli so Windows missing-agy hint path is exercised live
    Remove-Item -LiteralPath (Join-Path $envNonPathBin "agy.cmd") -Force
    & curl.exe -fsS -o NUL -X POST -H "Origin: ${envBaseURL}" "${envBaseURL}/settings/models" -d "action=refresh_cli&from_page=system"
    if ($LASTEXITCODE -ne 0) { throw "POST /settings/models action=refresh_cli failed (exit=$LASTEXITCODE)" }
    $sysTxt2 = [string](Invoke-WebRequest -Uri "${envBaseURL}/settings/system" -UseBasicParsing -TimeoutSec 10).Content
    $setupTxt2 = [string](Invoke-WebRequest -Uri "${envBaseURL}/setup" -UseBasicParsing -TimeoutSec 10).Content
    foreach ($pair in @(@{ name = "/settings/system(no-agy)"; txt = $sysTxt2 }, @{ name = "/setup(no-agy)"; txt = $setupTxt2 })) {
      if ($pair.txt -match 'which\s+agy') { throw "$($pair.name) leaked Unix 'which agy' hint when agy is missing" }
      if ($pair.txt -match '未安装\s+未安装' -or $pair.txt -match '<span class="cli-tool-status-hint">\s*未安装\s*</span>') {
        throw "$($pair.name) rendered duplicate '未安装 未安装' copy when agy is missing"
      }
      if ($pair.txt -notmatch '未在本机检测到可执行文件') {
        throw "$($pair.name) missing humanized CLI uninstalled guidance copy"
      }
      $missingAgyMatch = [regex]::Match($pair.txt, '<div class="cli-tool-row[^"]*" data-cli-name="agy"[^>]*>[\s\S]*?</div>\s*</div>')
      if (-not $missingAgyMatch.Success -or ($missingAgyMatch.Value -notmatch 'where\.exe\s+agy')) {
        throw "$($pair.name) missing Windows-specific 'where.exe agy' hint on agy row"
      }
    }
    Write-Host "   [PASS] Win-E2E 3.8/6: CODEX_HOME (Chinese+Space, 0 ~/.codex) + non-PATH agy + 0 'which agy' + 'where.exe agy' + 0 duplicate '未安装' passed!"
  } finally {
    if ($envDaemon -and -not $envDaemon.HasExited) {
      & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $envDaemon.Id 2>$null | Out-Null
      $envDaemon.WaitForExit(5000) | Out-Null
    }
    foreach ($ek in $envKeysToSave) {
      [Environment]::SetEnvironmentVariable($ek, $savedEnvMap[$ek], "Process")
    }
    Remove-Item -LiteralPath $envOutLog, $envErrLog -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $envE2ERoot) { Remove-DirectoryWithRetry $envE2ERoot 10 }
  }

  # Stage 4/6: Portable vteam.exe + subst Cross-Drive Workspace + broken-isolated Data Protection Mode
  $requirePortable = -not [string]::IsNullOrWhiteSpace($PortableDir)
  $resolvedPortDir = $PortableDir
  if ([string]::IsNullOrWhiteSpace($resolvedPortDir)) {
    $fallbackPortDir = Join-Path $env:RUNNER_TEMP "vt-win-portable"
    if (Test-Path -LiteralPath $fallbackPortDir) { $resolvedPortDir = $fallbackPortDir }
  }
  $baseURL2 = $null
  if (-not [string]::IsNullOrWhiteSpace($resolvedPortDir)) {
    Write-Host "==> [Win-E2E 4/6] Starting Instance #2 (Portable vteam.exe + subst cross-drive workspace + broken-isolated fault isolation)..."
    $portVteamItem = Get-ChildItem -LiteralPath $resolvedPortDir -Filter "vteam.exe" -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $portVteamItem) { throw "PortableDir '$resolvedPortDir' does not contain vteam.exe" }
    $portableExePath = $portVteamItem.FullName
    $portableExeDir = $portVteamItem.DirectoryName

    foreach ($drv in @('V', 'W', 'X', 'Y', 'Z')) {
      if (-not (Test-Path "${drv}:\")) { $substDrv = $drv; break }
    }
    if (-not $substDrv) { throw "No free drive letter among V..Z available for subst cross-drive test" }
    if (Test-Path -LiteralPath $substBacking) { Remove-Item -LiteralPath $substBacking -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $substBacking | Out-Null
    & subst.exe "${substDrv}:" "$substBacking"
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path "${substDrv}:\")) { throw "subst ${substDrv}: -> $substBacking failed (exit=$LASTEXITCODE)" }
    $substMounted = $true

    $substRoot = "${substDrv}:\Valid Team 跨盘工作区"
    New-Item -ItemType Directory -Force -Path $substRoot | Out-Null
    $substSecFile = Join-Path $substRoot "security.toml"
    [System.IO.File]::WriteAllBytes($substSecFile, [System.Text.Encoding]::ASCII.GetBytes($secToml))

    $brokenDir = Join-Path $substRoot "broken-isolated"
    Write-Utf8NoBom (Join-Path $brokenDir "project.toml") ("name = `"损坏隔离测试`"`nwork_start = `"09:00`"`nwork_end = `"18:30`"`n")
    Write-Utf8NoBom (Join-Path $brokenDir "workspace\分析报告\抢救说明.md") "# 抢救说明`n损坏库隔离模式下成果完好。`n"
    [System.IO.File]::WriteAllBytes((Join-Path $brokenDir "state.db"), [System.Text.Encoding]::ASCII.GetBytes("corrupted-not-a-sqlite-file"))

    $port2 = Get-FreeLoopbackPort
    $addr2 = "127.0.0.1:$port2"
    $baseURL2 = "http://$addr2"
    # WorkingDirectory MUST stay on C: ($portableExeDir), never on ${substDrv}:\ so subst /D can unmount cleanly!
    $portDaemon = Start-Process -FilePath $portableExePath -ArgumentList @("-addr", $addr2, "-root", "`"$substRoot`"", "-security", "`"$substSecFile`"") -WorkingDirectory $portableExeDir -PassThru -WindowStyle Hidden -RedirectStandardOutput $portOutLog -RedirectStandardError $portErrLog

    $status2 = Wait-VteamReady $portDaemon $baseURL2 $portOutLog $portErrLog "Instance#2(Portable+Subst)"
    if (-not $status2.canary_ok -or [int]$status2.isolated_project_count -ne 1) {
      throw "Instance#2 /api/status expected canary_ok=true & isolated_project_count=1, got canary_ok=$($status2.canary_ok) isolated=$($status2.isolated_project_count)"
    }

    $portProjName = "portable-跨盘项目"
    $encPortProj = [uri]::EscapeDataString($portProjName)
    Assert-CreateProject $baseURL2 $substRoot $portProjName "inst2" | Out-Null
    Assert-ZipExport "${baseURL2}/projects/${encPortProj}/export-backup" (Join-Path $env:RUNNER_TEMP "win-portable-backup.zip") "Instance#2 portable" | Out-Null
    Assert-ZipExport "${baseURL2}/projects/broken-isolated/export-backup?salvage=1" (Join-Path $env:RUNNER_TEMP "win-broken-salvage.zip") "Instance#2 broken-salvage" | Out-Null
    Write-Host "   [PASS] Portable vteam.exe + subst ${substDrv}: cross-drive SQLite + isolated_project_count=1 + ?salvage=1 passed!"
  } elseif ($requirePortable) {
    throw "PortableDir was requested ('$PortableDir') but could not be resolved"
  }

  # Stage 5/6: Native .NET ClientWebSocket -> msedge.exe --headless=new Real UI Inspection (0 npm/pip)
  Write-Host "==> [Win-E2E 5/6] Running headless Microsoft Edge CDP real browser UI & viewport inspection..."
  $edgeCandidates = @()
  $edgeCmd = Get-Command "msedge.exe" -ErrorAction SilentlyContinue
  if ($edgeCmd -and $edgeCmd.Source) { $edgeCandidates += $edgeCmd.Source }
  $edgeCandidates += @("C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", "C:\Program Files\Microsoft\Edge\Application\msedge.exe")
  $edgeExe = $edgeCandidates | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
  if (-not $edgeExe) { throw "msedge.exe not found on Windows runner" }

  $cdpPort = Get-FreeLoopbackPort
  if (Test-Path -LiteralPath $edgeUserDataDir) { Remove-Item -LiteralPath $edgeUserDataDir -Recurse -Force }
  New-Item -ItemType Directory -Force -Path $edgeUserDataDir | Out-Null
  $edgeProc = Start-Process -FilePath $edgeExe -ArgumentList @("--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check", "--remote-debugging-port=$cdpPort", "--user-data-dir=`"$edgeUserDataDir`"", "about:blank") -WorkingDirectory $env:RUNNER_TEMP -PassThru -WindowStyle Hidden

  $wsUrl = $null
  for ($i = 0; $i -lt 60; $i++) {
    if ($edgeProc.HasExited) { throw "msedge.exe exited prematurely with code $($edgeProc.ExitCode)" }
    try {
      $targets = Invoke-RestMethod -Uri "http://127.0.0.1:$cdpPort/json/list" -Method Get -TimeoutSec 2
      $pageTarget = @($targets) | Where-Object { $_.type -eq "page" -and $_.webSocketDebuggerUrl } | Select-Object -First 1
      if ($pageTarget) { $wsUrl = [string]$pageTarget.webSocketDebuggerUrl; break }
    } catch {}
    Start-Sleep -Milliseconds 200
  }
  if (-not $wsUrl) { throw "Timed out waiting for Edge CDP webSocketDebuggerUrl on 127.0.0.1:$cdpPort" }

  $cdpSocket = [System.Net.WebSockets.ClientWebSocket]::new()
  $connCts = [System.Threading.CancellationTokenSource]::new(15000)
  try { $cdpSocket.ConnectAsync([Uri]$wsUrl, $connCts.Token).GetAwaiter().GetResult() } finally { $connCts.Dispose() }

  $script:cdpNextId = 1
  $script:cdpPageErrors = [System.Collections.Generic.List[string]]::new()
  $script:cdpConsoleErrors = [System.Collections.Generic.List[string]]::new()

  function Handle-CdpEvent($Msg) {
    if (-not $Msg -or -not $Msg.method) { return }
    if ($Msg.method -eq "Runtime.exceptionThrown") {
      $desc = ""
      if ($Msg.params -and $Msg.params.exceptionDetails) {
        $desc = [string]$Msg.params.exceptionDetails.text
        if ($Msg.params.exceptionDetails.exception -and $Msg.params.exceptionDetails.exception.description) {
          $desc = "$desc $($Msg.params.exceptionDetails.exception.description)"
        }
      }
      $script:cdpPageErrors.Add($desc.Trim())
    } elseif ($Msg.method -eq "Runtime.consoleAPICalled" -and $Msg.params -and $Msg.params.type -eq "error") {
      $parts = foreach ($a in @($Msg.params.args)) {
        if ($null -ne $a.value) { [string]$a.value } elseif ($a.description) { [string]$a.description }
      }
      $joined = ($parts -join " ").Trim()
      if ($joined -notmatch "favicon\.ico") { $script:cdpConsoleErrors.Add("console.error: $joined") }
    } elseif ($Msg.method -eq "Log.entryAdded" -and $Msg.params -and $Msg.params.entry -and $Msg.params.entry.level -eq "error") {
      $u = [string]$Msg.params.entry.url
      $t = [string]$Msg.params.entry.text
      if ($u -notmatch "favicon\.ico" -and $t -notmatch "favicon\.ico") { $script:cdpConsoleErrors.Add("log.error: $t ($u)") }
    }
  }

  function Receive-CdpJson([System.Net.WebSockets.ClientWebSocket]$Sock, [int]$TimeoutMs = 15000) {
    $ms = [System.IO.MemoryStream]::new()
    $buf = [byte[]]::new(16384)
    $seg = [System.ArraySegment[byte]]::new($buf)
    $rCts = [System.Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
      do {
        $res = $Sock.ReceiveAsync($seg, $rCts.Token).GetAwaiter().GetResult()
        if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) { throw "Edge CDP WebSocket closed unexpectedly" }
        if ($res.Count -gt 0) { $ms.Write($buf, 0, $res.Count) }
      } while (-not $res.EndOfMessage)
      return ([System.Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json)
    } finally {
      $rCts.Dispose()
      $ms.Dispose()
    }
  }

  function Invoke-CdpCommand([string]$Method, [hashtable]$Params = @{}) {
    $id = $script:cdpNextId
    $script:cdpNextId = $id + 1
    $bytes = [System.Text.Encoding]::UTF8.GetBytes((@{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Depth 10 -Compress))
    $sCts = [System.Threading.CancellationTokenSource]::new(10000)
    try {
      $cdpSocket.SendAsync([System.ArraySegment[byte]]::new($bytes), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sCts.Token).GetAwaiter().GetResult()
    } finally {
      $sCts.Dispose()
    }
    while ($true) {
      $msg = Receive-CdpJson $cdpSocket 15000
      if ($null -ne $msg.id -and [int]$msg.id -eq $id) {
        if ($msg.error) { throw "CDP $Method error: $($msg.error.message)" }
        return $msg.result
      }
      Handle-CdpEvent $msg
    }
  }

  function Invoke-CdpEval([string]$Expression) {
    $res = Invoke-CdpCommand "Runtime.evaluate" @{ expression = $Expression; returnByValue = $true; awaitPromise = $true }
    if ($res.exceptionDetails) { throw "JS evaluation threw exception: $($res.exceptionDetails.text) | expr=$Expression" }
    return $res.result.value
  }

  function Navigate-CdpAndWait([string]$TargetUrl) {
    try { Invoke-CdpEval "window.__vt_nav_seq = 1; true" | Out-Null } catch {}
    Invoke-CdpCommand "Page.navigate" @{ url = $TargetUrl } | Out-Null
    for ($w = 0; $w -lt 60; $w++) {
      try {
        if ((Invoke-CdpEval "(!window.__vt_nav_seq && document.readyState === 'complete')") -eq $true) { return }
      } catch {}
      Start-Sleep -Milliseconds 150
    }
    throw "Timed out waiting for Edge navigation readyState=complete on $TargetUrl"
  }

  function Reload-CdpAndWait {
    Invoke-CdpEval "window.__vt_reload_seq = 1; true" | Out-Null
    Invoke-CdpCommand "Page.reload" @{ ignoreCache = $false } | Out-Null
    for ($w = 0; $w -lt 60; $w++) {
      try {
        if ((Invoke-CdpEval "(!window.__vt_reload_seq && document.readyState === 'complete')") -eq $true) { return }
      } catch {}
      Start-Sleep -Milliseconds 150
    }
    throw "Timed out waiting for Edge Page.reload readyState=complete"
  }

  function Assert-ZeroHorizontalOverflow([string]$PageLabel) {
    foreach ($vp in @(@{ width = 1440; height = 900; mobile = $false }, @{ width = 375; height = 812; mobile = $true })) {
      Invoke-CdpCommand "Emulation.setDeviceMetricsOverride" @{ width = [int]$vp.width; height = [int]$vp.height; deviceScaleFactor = 1; mobile = [bool]$vp.mobile } | Out-Null
      Start-Sleep -Milliseconds 80
      $dims = Invoke-CdpEval "JSON.stringify({ sw: document.documentElement.scrollWidth, iw: window.innerWidth })" | ConvertFrom-Json
      if ([int]$dims.sw -gt [int]$dims.iw) {
        throw "Horizontal overflow on $PageLabel at $($vp.width)x$($vp.height): scrollWidth=$($dims.sw) > innerWidth=$($dims.iw)"
      }
    }
    Invoke-CdpCommand "Emulation.clearDeviceMetricsOverride" @{} | Out-Null
  }

  Invoke-CdpCommand "Page.enable" @{} | Out-Null
  Invoke-CdpCommand "Runtime.enable" @{} | Out-Null
  Invoke-CdpCommand "Log.enable" @{} | Out-Null

  # UI Check 1: Home / Workspace Rail
  Navigate-CdpAndWait "${baseURL}/"
  $homeCheck = Invoke-CdpEval "JSON.stringify({ rail: !!document.querySelector('.ws-rail'), badTokens: /\b(undefined|NaN)\b/.test(document.body ? document.body.innerText : '') })" | ConvertFrom-Json
  if (-not $homeCheck.rail -or $homeCheck.badTokens) {
    throw "Edge UI Check 1 (/) failed: ws-rail=$($homeCheck.rail) badTokens=$($homeCheck.badTokens)"
  }
  Write-Host "   [PASS] Edge UI Check 1 (/): .ws-rail rendered & zero undefined/NaN text"

  # UI Check 2: Cold-migrated legacy project overview & task detail drawer
  Navigate-CdpAndWait "${baseURL}/projects/${legacyEnc}"
  if (-not (Invoke-CdpEval "!!document.querySelector('#task-row-20261101T100000-leg01')")) {
    throw "Edge UI Check 2 (/projects/$legacyName) missing #task-row-20261101T100000-leg01"
  }
  Invoke-CdpEval "openTaskDetail('20261101T100000-leg01'); true" | Out-Null
  $drawerLoaded = $false
  for ($d = 0; $d -lt 25; $d++) {
    if (Invoke-CdpEval "(function(){ var el = document.querySelector('#task-detail-drawer'); return !!(el && el.textContent && el.textContent.indexOf('历史冷迁移任务') !== -1); })()") {
      $drawerLoaded = $true; break
    }
    Start-Sleep -Milliseconds 120
  }
  if (-not $drawerLoaded) { throw "Edge UI Check 2: #task-detail-drawer did not render '历史冷迁移任务' within 3s" }
  Write-Host "   [PASS] Edge UI Check 2 (/projects/$legacyName): #task-row-20261101T100000-leg01 + openTaskDetail drawer verified"

  # UI Check 3: Role chat draft persistence, sidebar badge, reload survival & dual-viewport zero overflow
  Navigate-CdpAndWait "${baseURL}/projects/${encProj}?view=role&to=system"
  $roleCheck = Invoke-CdpEval "JSON.stringify({ ok: !!(document.querySelector('#directive-form') && document.querySelector('#directive-body')), href: String(location.href || ''), title: String(document.title || '') })" | ConvertFrom-Json
  if (-not $roleCheck.ok) {
    throw "Edge UI Check 3: #directive-form or #directive-body missing on role chat page (href=$($roleCheck.href) title=$($roleCheck.title))"
  }
  $draftSavedJson = Invoke-CdpEval @'
(function(){
  var ta = document.querySelector('#directive-body');
  ta.value = 'Windows Edge 草稿持久化实测';
  ta.dispatchEvent(new Event('input', { bubbles: true }));
  return JSON.stringify({
    stored: localStorage.getItem('vteam.draft.chat:win-team-中文:system'),
    badge: !!document.querySelector('.nav-draft-badge')
  });
})()
'@
  $draftSaved = $draftSavedJson | ConvertFrom-Json
  if ($draftSaved.stored -ne "Windows Edge 草稿持久化实测" -or -not $draftSaved.badge) {
    throw "Edge UI Check 3 draft save failed: stored='$($draftSaved.stored)' badge=$($draftSaved.badge)"
  }
  Reload-CdpAndWait
  $restoredVal = Invoke-CdpEval "document.querySelector('#directive-body') ? document.querySelector('#directive-body').value : ''"
  if ($restoredVal -ne "Windows Edge 草稿持久化实测") {
    throw "Edge UI Check 3 draft reload restore failed: got '$restoredVal'"
  }
  $clearedNull = Invoke-CdpEval @'
(function(){
  var ta = document.querySelector('#directive-body');
  ta.value = '';
  ta.dispatchEvent(new Event('input', { bubbles: true }));
  return localStorage.getItem('vteam.draft.chat:win-team-中文:system') === null;
})()
'@
  if (-not $clearedNull) { throw "Edge UI Check 3 draft clear failed: localStorage key was not removed" }
  Assert-ZeroHorizontalOverflow "role-chat(win-team-中文)"
  Write-Host "   [PASS] Edge UI Check 3 (role chat): draft save/badge/reload/clear + 1440x900 & 375x812 zero overflow verified"

  # UI Check 3b: Global network proxy save, credential redaction (zero plaintext leak) & restore to default
  $proxySaveRaw = & curl.exe -fsS -X POST `
    -H "Origin: ${baseURL}" `
    -H "X-Requested-With: XMLHttpRequest" `
    "${baseURL}/settings/proxy" `
    --data-urlencode "mode=custom" `
    --data-urlencode "proxy_url=http://winuser:WinProxySecret99@127.0.0.1:18899" `
    --data-urlencode "no_proxy=localhost,127.0.0.1"
  $proxySaveObj = $proxySaveRaw | ConvertFrom-Json
  if (-not $proxySaveObj.ok) {
    throw "Edge UI Check 3b: POST /settings/proxy (custom) did not return ok=true: $proxySaveRaw"
  }
  try {
    Navigate-CdpAndWait "${baseURL}/settings/system#sys-proxy"
    $proxyCheckJson = Invoke-CdpEval @'
(function(){
  var card = document.querySelector('#sys-network-proxy-card');
  var urlInput = document.querySelector('#sys-network-proxy-form input[name="proxy_url"]');
  var html = document.documentElement ? document.documentElement.outerHTML : '';
  var inputs = Array.from(document.querySelectorAll('input,textarea'));
  var leakedInput = inputs.some(function(el){ return String(el.value || '').indexOf('WinProxySecret99') !== -1; });
  return JSON.stringify({
    hasCard: !!card,
    inputVal: urlInput ? String(urlInput.value || '') : '',
    hasHostPort: !!(urlInput && String(urlInput.value || '').indexOf('127.0.0.1:18899') !== -1),
    leakedHtml: html.indexOf('WinProxySecret99') !== -1,
    leakedInput: leakedInput
  });
})()
'@
    $proxyCheck = $proxyCheckJson | ConvertFrom-Json
    if (-not $proxyCheck.hasCard -or -not $proxyCheck.hasHostPort -or $proxyCheck.leakedHtml -or $proxyCheck.leakedInput) {
      throw "Edge UI Check 3b (/settings/system#sys-proxy) failed: hasCard=$($proxyCheck.hasCard) hasHostPort=$($proxyCheck.hasHostPort) inputVal='$($proxyCheck.inputVal)' leakedHtml=$($proxyCheck.leakedHtml) leakedInput=$($proxyCheck.leakedInput)"
    }
    Assert-ZeroHorizontalOverflow "system-settings(proxy)"
    Write-Host "   [PASS] Edge UI Check 3b (/settings/system#sys-proxy): masked proxy host:port rendered, zero plaintext password leak & dual-viewport zero overflow verified"
  } finally {
    $proxyResetRaw = & curl.exe -fsS -X POST `
      -H "Origin: ${baseURL}" `
      -H "X-Requested-With: XMLHttpRequest" `
      "${baseURL}/settings/proxy" `
      --data-urlencode "mode=default"
    $proxyResetObj = $proxyResetRaw | ConvertFrom-Json
    if (-not $proxyResetObj.ok) {
      throw "Edge UI Check 3b: POST /settings/proxy (default restore) failed: $proxyResetRaw"
    }
  }

  # UI Check 4: Instance #2 Data Protection Mode page & dual-viewport zero overflow
  if ($baseURL2) {
    Navigate-CdpAndWait "${baseURL2}/projects/broken-isolated"
    $protCheckJson = Invoke-CdpEval @'
(function(){
  var bodyTxt = document.body ? document.body.innerText : '';
  var btn = document.querySelector('#protection-salvage-export-btn');
  var href = btn ? (btn.getAttribute('href') || '') : '';
  return JSON.stringify({
    hasBanner: bodyTxt.indexOf('已为项目开启数据保护模式') !== -1,
    hasSalvageBtn: !!(btn && href.indexOf('/export-backup?salvage=1') !== -1)
  });
})()
'@
    $protCheck = $protCheckJson | ConvertFrom-Json
    if (-not $protCheck.hasBanner -or -not $protCheck.hasSalvageBtn) {
      throw "Edge UI Check 4 (/projects/broken-isolated) failed: hasBanner=$($protCheck.hasBanner) hasSalvageBtn=$($protCheck.hasSalvageBtn)"
    }
    Assert-ZeroHorizontalOverflow "protection-panel(broken-isolated)"
    Write-Host "   [PASS] Edge UI Check 4 (/projects/broken-isolated): Data Protection Mode banner + salvage button + dual-viewport zero overflow verified"
  }

  Invoke-CdpEval "true" | Out-Null
  if ($script:cdpPageErrors.Count -gt 0 -or $script:cdpConsoleErrors.Count -gt 0) {
    throw "Edge headless UI detected runtime errors! pageerror($($script:cdpPageErrors.Count)): [$($script:cdpPageErrors -join ' | ')] console/log error($($script:cdpConsoleErrors.Count)): [$($script:cdpConsoleErrors -join ' | ')]"
  }
  Write-Host "   [PASS] Edge CDP global error gate: pageerror=0 & console/log error=0!"
} catch {
  $hadPrimaryError = $true
  throw
} finally {
  Write-Host "==> [Win-E2E 6/6] Executing strict 4-step teardown & verifying zero lingering Windows/subst locks..."

  # Step 1: Close CDP WebSocket, terminate Edge process tree, remove & verify $edgeUserDataDir
  if ($cdpSocket) {
    try {
      if ($cdpSocket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
        $closeCts = [System.Threading.CancellationTokenSource]::new(2000)
        try { $cdpSocket.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, "done", $closeCts.Token).GetAwaiter().GetResult() } finally { $closeCts.Dispose() }
      }
    } catch {} finally { $cdpSocket.Dispose() }
  }
  if ($edgeProc) {
    if (-not $edgeProc.HasExited) {
      & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $edgeProc.Id 2>$null | Out-Null
      $edgeProc.WaitForExit(5000) | Out-Null
    }
    Remove-DirectoryWithRetry $edgeUserDataDir 12
    if (-not $hadPrimaryError -and (Test-Path -LiteralPath $edgeUserDataDir)) {
      throw "Lingering Edge file lock prevented removal of $edgeUserDataDir"
    }
  }

  # Step 2: Terminate Instance #2 (portable daemon)
  if ($portDaemon -and -not $portDaemon.HasExited) {
    & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $portDaemon.Id 2>$null | Out-Null
    $portDaemon.WaitForExit(5000) | Out-Null
  }

  # Step 3: Remove cross-drive workspace $substRoot & assert zero lingering SQLite -wal/-shm locks
  if ($substRoot -and (Test-Path -LiteralPath $substRoot)) {
    Remove-DirectoryWithRetry $substRoot 10
    if (-not $hadPrimaryError -and (Test-Path -LiteralPath $substRoot)) {
      throw "Lingering cross-drive SQLite file lock prevented removal of $substRoot"
    }
  }

  # Step 4: Unmount subst drive letter & remove backing directory
  if ($substMounted -and $substDrv) {
    & subst.exe "${substDrv}:" /D 2>$null | Out-Null
    if (-not $hadPrimaryError -and (Test-Path "${substDrv}:\")) {
      throw "subst ${substDrv}: /D failed to unmount virtual drive"
    }
  }
  if (Test-Path -LiteralPath $substBacking) { Remove-DirectoryWithRetry $substBacking 10 }

  # Terminate Instance #1 daemon & clean temp logs/zips
  if ($daemon -and -not $daemon.HasExited) {
    & "$env:SystemRoot\System32\taskkill.exe" /T /F /PID $daemon.Id 2>$null | Out-Null
    $daemon.WaitForExit(5000) | Out-Null
  }
  Remove-Item -LiteralPath @(
    (Join-Path $env:RUNNER_TEMP "win-team-backup.zip"),
    (Join-Path $env:RUNNER_TEMP "win-team-salvage.zip"),
    (Join-Path $env:RUNNER_TEMP "win-portable-backup.zip"),
    (Join-Path $env:RUNNER_TEMP "win-broken-salvage.zip"),
    (Join-Path $env:RUNNER_TEMP "win-e2e-setup-hdr.txt"),
    (Join-Path $env:RUNNER_TEMP "win-e2e-setup-resp.html"),
    $outLog, $errLog, $portOutLog, $portErrLog
  ) -Force -ErrorAction SilentlyContinue
}

Remove-DirectoryWithRetry $e2eRoot 10
if (Test-Path -LiteralPath $e2eRoot) { throw "Lingering Windows file handle prevented removal of $e2eRoot" }
$dirtyShellScript = Join-Path $PSScriptRoot "windows_dirty_env_and_shell_e2e.ps1"
$setupExePath = Join-Path $DownloadDir "ValidTeam-Setup.exe"
if (-not (Test-Path -LiteralPath $dirtyShellScript)) { throw "Missing required modular script: $dirtyShellScript" }
if (-not (Test-Path -LiteralPath $setupExePath)) { throw "Missing required installer for dirty-env E2E: $setupExePath" }
& $dirtyShellScript -SetupExe $setupExePath -DownloadDir $DownloadDir
Write-Host "✅ WIN_REAL_E2E_OK: Native Test Bins + Real-LLM 4-Tools + Legacy/Portable/Subst/Edge UI + Dirty-Env/CP936/Proxy/Shell DPI+Icon passed!"
