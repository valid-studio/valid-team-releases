#!/usr/bin/env bash
# Public Clean-VM macOS Black-Box OTA E2E Harness (Zero App Source Code)
# Resolves PREV_TAG != TARGET_TAG from published non-prerelease releases.
# - When PREV_TAG < v1.3.0 (v1.3.0 transition): logs [TRANSITION-v1.3.0] and runs --verify-online-release-check.
# - When PREV_TAG >= v1.3.0 (v1.3.1+ automatic activation): installs PREV_TAG into /Applications/Valid Team.app
#   and executes a real 2-phase gated live LaunchServices A->B upgrade with all 4 hard assertions.
set -euo pipefail

export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

RELEASE_REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
TARGET_ASSET_DIR="${TARGET_ASSET_DIR:-$HOME/Downloads/validteam-installer}"
TARGET_MANIFEST="${TARGET_ASSET_DIR}/latest-macos.json"
TARGET_ZIP="${TARGET_ASSET_DIR}/ValidTeam-macos.zip"
APP_PATH="/Applications/Valid Team.app"
BASE_URL="http://127.0.0.1:8787"

for req in "${TARGET_MANIFEST}" "${TARGET_ZIP}"; do
  if [ ! -s "${req}" ]; then
    echo "❌ Missing target macOS release asset: ${req}" >&2
    exit 1
  fi
done

read -r TARGET_VERSION TARGET_BUILD RESOLVED_TARGET_TAG <<EOF
$(python3 - "${TARGET_MANIFEST}" "${TARGET_TAG:-}" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as f:
    m = json.load(f)
ver = str(m.get("version", "")).lstrip("vV").strip()
bld = str(m.get("build", "")).strip()
tag = str(m.get("tag", "")).strip()
if not tag:
    arg_tag = sys.argv[2].strip()
    tag = arg_tag if (arg_tag and arg_tag != "latest") else (f"v{ver}" if ver else "")
print(f"{ver} {bld} {tag}")
PYEOF
)
EOF

if [ -z "${TARGET_VERSION}" ] || [ -z "${TARGET_BUILD}" ] || [ -z "${RESOLVED_TARGET_TAG}" ]; then
  echo "❌ Failed to resolve target release metadata from ${TARGET_MANIFEST}" >&2
  exit 1
fi

GH_BIN=""
for cand in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
  if [ -x "${cand}" ]; then
    GH_BIN="${cand}"
    break
  fi
done
if [ -z "${GH_BIN}" ]; then
  echo "❌ gh CLI not found on macOS runner" >&2
  exit 1
fi

RELEASES_JSON="$("${GH_BIN}" release list --repo "${RELEASE_REPO}" --exclude-drafts --exclude-pre-releases --limit 20 --json tagName)"
PREV_TAG="$(python3 - "${RELEASES_JSON}" "${RESOLVED_TARGET_TAG}" <<'PYEOF'
import json, sys
items = json.loads(sys.argv[1])
target = sys.argv[2].strip()
for it in items:
    t = str(it.get("tagName", "")).strip()
    if t and t != target:
        print(t)
        break
PYEOF
)"

if [ -z "${PREV_TAG}" ]; then
  echo "❌ No previous stable release found with tagName != ${RESOLVED_TARGET_TAG} in ${RELEASE_REPO}" >&2
  exit 1
fi

PREV_VERSION="${PREV_TAG#v}"
IS_PREV_GTE_130="$(python3 - "${PREV_VERSION}" <<'PYEOF'
import re, sys
raw = sys.argv[1].lstrip("vV").split("-", 1)[0]
parts = [int(x) for x in re.findall(r"\d+", raw)[:3]]
while len(parts) < 3:
    parts.append(0)
print("1" if tuple(parts) >= (1, 3, 0) else "0")
PYEOF
)"

echo "==> [Clean-VM macOS OTA] Resolved PREV_TAG=${PREV_TAG} -> TARGET_TAG=${RESOLVED_TARGET_TAG} (v${TARGET_VERSION}, build=${TARGET_BUILD})"

if [ "${IS_PREV_GTE_130}" != "1" ]; then
  echo "[TRANSITION-v1.3.0] Previous stable release ${PREV_TAG} (< v1.3.0) predates macOS loopback auto-confirm hook; running --verify-online-release-check."
  "${APP_PATH}/Contents/MacOS/ValidTeam" --verify-online-release-check
  exit 0
fi

# PREV_TAG >= v1.3.0: Mandatory real dual-notarized LaunchServices live A->B upgrade (never silently skip)
WORK_DIR="$(mktemp -d "${RUNNER_TEMP:-/tmp}/vt-mac-clean-ota.XXXXXX")"
SRV_DIR="${WORK_DIR}/srv"
CACHE_DIR="${WORK_DIR}/ota-cache"
GATE_SCRIPT="${WORK_DIR}/ota_gate_server.py"
GATE_FLAG="${WORK_DIR}/allow_ota.flag"
HIT_LOG="${WORK_DIR}/http_hits.log"
PREV_DL_DIR="${WORK_DIR}/prev-dl"
PREV_DMG="${PREV_DL_DIR}/ValidTeam.dmg"
HTTP_PID=""

PROJECT_NAME="OTA保留验证"
PROJECT_ENC="$(python3 -c 'import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))' "${PROJECT_NAME}")"
APP_SUPPORT_DIR="$HOME/Library/Application Support/hk.4l.valid-team"
PROJECT_DIR="${APP_SUPPORT_DIR}/Projects/${PROJECT_NAME}"
PROJECT_TOML="${PROJECT_DIR}/project.toml"
STATE_DB="${PROJECT_DIR}/state.db"
SEC_TOML="${APP_SUPPORT_DIR}/security.toml"
ROLLBACK_APP="$HOME/Library/Application Support/valid-team/rollback-slot/Valid Team.app"

stop_live_apps() {
  pkill -f "/Applications/Valid Team.app/Contents/MacOS/ValidTeam" 2>/dev/null || true
  pkill -f "/Applications/Valid Team.app/Contents/Resources/bin/vteam" 2>/dev/null || true
  sleep 0.6
  pkill -9 -f "/Applications/Valid Team.app/Contents/MacOS/ValidTeam" 2>/dev/null || true
  pkill -9 -f "/Applications/Valid Team.app/Contents/Resources/bin/vteam" 2>/dev/null || true
  if [ -n "${HTTP_PID}" ] && kill -0 "${HTTP_PID}" 2>/dev/null; then
    kill "${HTTP_PID}" 2>/dev/null || true
    wait "${HTTP_PID}" 2>/dev/null || true
  fi
  HTTP_PID=""
}

cleanup() {
  local rc=$?
  if [ "${rc}" -ne 0 ]; then
    echo "--- [Diagnostic] Clean-VM macOS OTA failure logs (redacted) ---"
    if [ -f "${CACHE_DIR}/last-update-error.log" ]; then
      tail -n 30 "${CACHE_DIR}/last-update-error.log" | sed -E 's/oc_sk_[A-Za-z0-9_-]+/[REDACTED]/g; s/sk-[A-Za-z0-9]{16,}/[REDACTED]/g' || true
    fi
    if [ -f "$HOME/Library/Logs/ValidTeam/vteam.log" ]; then
      tail -n 40 "$HOME/Library/Logs/ValidTeam/vteam.log" | sed -E 's/oc_sk_[A-Za-z0-9_-]+/[REDACTED]/g; s/sk-[A-Za-z0-9]{16,}/[REDACTED]/g' || true
    fi
    [ -f "${HIT_LOG}" ] && cat "${HIT_LOG}" || true
  fi
  stop_live_apps
  rm -rf "${PROJECT_DIR}" "${WORK_DIR}" || true
}
trap cleanup EXIT

mkdir -p "${SRV_DIR}" "${CACHE_DIR}" "${APP_SUPPORT_DIR}" "${PREV_DL_DIR}"

echo "==> [1/4] Downloading & installing previous notarized release ${PREV_TAG} into ${APP_PATH}..."
"${GH_BIN}" release download "${PREV_TAG}" --repo "${RELEASE_REPO}" -p "ValidTeam.dmg" -D "${PREV_DL_DIR}" --clobber
test -s "${PREV_DMG}"

stop_live_apps
rm -rf "${APP_PATH}" "${ROLLBACK_APP}"
MOUNT_DIR="/Volumes/Valid Team Prev"
hdiutil detach "${MOUNT_DIR}" >/dev/null 2>&1 || true
hdiutil attach "${PREV_DMG}" -nobrowse -readonly -mountpoint "${MOUNT_DIR}"
/usr/bin/ditto "${MOUNT_DIR}/Valid Team.app" "${APP_PATH}"
hdiutil detach "${MOUNT_DIR}"
/usr/bin/xattr -dr com.apple.quarantine "${APP_PATH}" 2>/dev/null || true

PREV_PLIST_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
if [ "${PREV_PLIST_VER}" != "${PREV_VERSION}" ]; then
  echo "❌ Installed ${PREV_TAG} bundle has version ${PREV_PLIST_VER}, expected ${PREV_VERSION}" >&2
  exit 1
fi

HTTP_PORT="$(python3 - <<'PYEOF'
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.bind(("127.0.0.1", 0))
p = s.getsockname()[1]
s.close()
print(p)
PYEOF
)"

cp -f "${TARGET_ZIP}" "${SRV_DIR}/ValidTeam-macos.zip"
cp -f "${TARGET_ZIP}" "${SRV_DIR}/tampered-macos.zip"
python3 - "${SRV_DIR}/tampered-macos.zip" "${TARGET_MANIFEST}" "${SRV_DIR}/latest-macos.json" "${SRV_DIR}/bad-latest-macos.json" "${HTTP_PORT}" <<'PYEOF'
import json, sys
tampered_path, src_manifest, good_out, bad_out, port = sys.argv[1:6]
with open(tampered_path, "r+b") as f:
    f.seek(-1, 2)
    b = f.read(1)
    f.seek(-1, 2)
    f.write(bytes([b[0] ^ 0xFF]))
with open(src_manifest, "r", encoding="utf-8") as f:
    m = json.load(f)
good = dict(m)
good["zip_url"] = f"http://127.0.0.1:{port}/ValidTeam-macos.zip"
good.pop("github_api_asset_url", None)
with open(good_out, "w", encoding="utf-8") as f:
    json.dump(good, f, ensure_ascii=False, indent=2)
    f.write("\n")
bad = dict(good)
bad["zip_url"] = f"http://127.0.0.1:{port}/tampered-macos.zip"
with open(bad_out, "w", encoding="utf-8") as f:
    json.dump(bad, f, ensure_ascii=False, indent=2)
    f.write("\n")
PYEOF

cat > "${GATE_SCRIPT}" <<'PYEOF'
import argparse, http.server, os, socketserver, time

parser = argparse.ArgumentParser()
parser.add_argument("--dir", required=True)
parser.add_argument("--port", type=int, required=True)
parser.add_argument("--mode", choices=["bad", "gated"], required=True)
parser.add_argument("--flag", required=True)
parser.add_argument("--hit-log", required=True)
parser.add_argument("--gate-timeout", type=float, default=20.0)
args = parser.parse_args()

def log_hit(msg):
    with open(args.hit_log, "a", encoding="utf-8") as f:
        f.write(msg + "\n")
        f.flush()

class GatedHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=args.dir, **kw)

    def log_message(self, fmt, *a):
        pass

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path == "/latest-macos.json" and args.mode == "gated":
            log_hit("MANIFEST_WAITING")
            deadline = time.monotonic() + args.gate_timeout
            while not os.path.exists(args.flag):
                if time.monotonic() >= deadline:
                    log_hit("MANIFEST_GATE_TIMEOUT")
                    self.send_error(503, "gate timeout")
                    return
                time.sleep(0.05)
            log_hit("MANIFEST_RELEASED")
        elif path == "/tampered-macos.zip":
            log_hit("BAD_ASSET_SERVED")
        elif path == "/ValidTeam-macos.zip":
            log_hit("GOOD_ASSET_SERVED")
        super().do_GET()

class ReusableTCPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    allow_reuse_address = True
    daemon_threads = True

srv = ReusableTCPServer(("127.0.0.1", args.port), GatedHandler)
srv.serve_forever()
PYEOF

start_gate_server() {
  local mode="$1"
  : > "${HIT_LOG}"
  python3 "${GATE_SCRIPT}" \
    --dir "${SRV_DIR}" \
    --port "${HTTP_PORT}" \
    --mode "${mode}" \
    --flag "${GATE_FLAG}" \
    --hit-log "${HIT_LOG}" \
    --gate-timeout 20 &
  HTTP_PID=$!
  for _ in $(seq 1 30); do
    if curl -fsS "http://127.0.0.1:${HTTP_PORT}/bad-latest-macos.json" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

wait_api_status() {
  local expect_ver="$1"
  local expect_build="${2:-}"
  local max_sec="${3:-45}"
  for _ in $(seq 1 $((max_sec * 2))); do
    local raw
    raw="$(curl -fsS --max-time 2 "${BASE_URL}/api/status" 2>/dev/null || true)"
    if [ -n "${raw}" ]; then
      if python3 - "${raw}" "${expect_ver}" "${expect_build}" <<'PYEOF'
import json, sys
data = json.loads(sys.argv[1])
if not data.get("ok") or bool(data.get("bootstrapping", False)):
    sys.exit(1)
v = str(data.get("version", "")).lstrip("vV").strip()
b = str(data.get("build", "")).strip()
if v != sys.argv[2]:
    sys.exit(1)
if sys.argv[3] and b != sys.argv[3]:
    sys.exit(1)
sys.exit(0)
PYEOF
      then
        return 0
      fi
    fi
    sleep 0.5
  done
  return 1
}

cat > "${SEC_TOML}" <<'EOF'
default_model = "selftest/mock"

[[api]]
name = "selftest"
format = "openai"
base_url = "http://127.0.0.1:9/v1"
key = "sk-ci-unit-test-placeholder"
models = ["mock"]
EOF
chmod 600 "${SEC_TOML}"
SEC_SHA_BEFORE="$(shasum -a 256 "${SEC_TOML}" | awk '{print $1}')"

echo "==> [2/4] Phase 1 (Negative): Tampered package live rejection on ${PREV_TAG}..."
start_gate_server "bad"
# Note: intentionally DO NOT set VTEAM_OTA_E2E_SANDBOX_HOME so Clean-VM exercises production `open "$TARGET_APP"`!
VTEAM_OTA_CACHE_DIR="${CACHE_DIR}" \
VTEAM_MAC_OTA_AUTO_CONFIRM="1" \
VTEAM_OTA_MANIFEST_URL="http://127.0.0.1:${HTTP_PORT}/bad-latest-macos.json" \
VTEAM_SKIP_MOVE_PROMPT="1" \
VTEAM_HEADLESS_TEST="1" \
VALID_TEAM_SECRET_BACKEND="memory" \
CI="true" \
  "${APP_PATH}/Contents/MacOS/ValidTeam" --skip-move-prompt >/dev/null 2>&1 &

wait_api_status "${PREV_VERSION}" "" 40
P1_GUI_PID="$(pgrep -f '/Applications/Valid Team.app/Contents/MacOS/ValidTeam' | head -n 1 || true)"
P1_DAEMON_PID="$(pgrep -f '/Applications/Valid Team.app/Contents/Resources/bin/vteam' | head -n 1 || true)"
test -n "${P1_GUI_PID}" && test -n "${P1_DAEMON_PID}"

HDR_FILE="${WORK_DIR}/proj-hdr.txt"
curl -fsS -D "${HDR_FILE}" -o /dev/null -X POST "${BASE_URL}/projects" --data-urlencode "name=${PROJECT_NAME}"
grep -qE '^HTTP/[0-9.]+ 303' "${HDR_FILE}"
test -s "${PROJECT_TOML}" && test -s "${STATE_DB}"
PROJ_TOML_BEFORE="${WORK_DIR}/project.toml.before"
cp -f "${PROJECT_TOML}" "${PROJ_TOML_BEFORE}"
PROJ_SHA_BEFORE="$(shasum -a 256 "${PROJECT_TOML}" | awk '{print $1}')"

BAD_OK=0
for _ in $(seq 1 60); do
  if grep -q "BAD_ASSET_SERVED" "${HIT_LOG}" 2>/dev/null && [ -s "${CACHE_DIR}/last-update-error.log" ]; then
    BAD_OK=1
    break
  fi
  sleep 0.5
done
test "${BAD_OK}" -eq 1
if find "${CACHE_DIR}" -name '*.part' 2>/dev/null | grep -q .; then
  echo "❌ Leftover .part artifacts after bad package rejection" >&2
  exit 1
fi
kill -0 "${P1_GUI_PID}" 2>/dev/null
kill -0 "${P1_DAEMON_PID}" 2>/dev/null
wait_api_status "${PREV_VERSION}" "" 5

stop_live_apps

echo "==> [3/4] Phase 2 (Gated Positive): Live LaunchServices upgrade ${PREV_TAG} -> ${RESOLVED_TARGET_TAG}..."
rm -f "${GATE_FLAG}" "${CACHE_DIR}/last-update-error.log"
start_gate_server "gated"
VTEAM_OTA_CACHE_DIR="${CACHE_DIR}" \
VTEAM_MAC_OTA_AUTO_CONFIRM="1" \
VTEAM_OTA_MANIFEST_URL="http://127.0.0.1:${HTTP_PORT}/latest-macos.json" \
VTEAM_SKIP_MOVE_PROMPT="1" \
VTEAM_HEADLESS_TEST="1" \
VALID_TEAM_SECRET_BACKEND="memory" \
CI="true" \
  "${APP_PATH}/Contents/MacOS/ValidTeam" --skip-move-prompt >/dev/null 2>&1 &

wait_api_status "${PREV_VERSION}" "" 40
OLD_GUI_PID="$(pgrep -f '/Applications/Valid Team.app/Contents/MacOS/ValidTeam' | head -n 1 || true)"
OLD_DAEMON_PID="$(pgrep -f '/Applications/Valid Team.app/Contents/Resources/bin/vteam' | head -n 1 || true)"
test -n "${OLD_GUI_PID}" && test -n "${OLD_DAEMON_PID}"

printf 'go\n' > "${GATE_FLAG}"
wait_api_status "${TARGET_VERSION}" "${TARGET_BUILD}" 90

echo "==> [4/4] Enforcing 4 Hard Assertions on upgraded /Applications/Valid Team.app..."
DISK_VER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP_PATH}/Contents/Info.plist")"
DISK_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "${APP_PATH}/Contents/Info.plist")"
test "${DISK_VER}" = "${TARGET_VERSION}"
test "${DISK_BUILD}" = "${TARGET_BUILD}"
codesign --verify --deep --strict "${APP_PATH}"
xcrun stapler validate "${APP_PATH}"
# swapScript relaunches app B before completing ditto->rollback-slot & rm -rf .bak; poll up to 15s for settle
for _ in $(seq 1 60); do
  if [ ! -e "/Applications/.Valid Team.app.bak" ] && [ ! -e "/Applications/.Valid Team.app.new" ] && [ -f "${ROLLBACK_APP}/Contents/Info.plist" ]; then
    break
  fi
  sleep 0.25
done
test ! -e "/Applications/.Valid Team.app.bak"
test ! -e "/Applications/.Valid Team.app.new"
test -f "${ROLLBACK_APP}/Contents/Info.plist"

for _ in $(seq 1 20); do
  if ! kill -0 "${OLD_GUI_PID}" 2>/dev/null && ! kill -0 "${OLD_DAEMON_PID}" 2>/dev/null; then
    break
  fi
  sleep 0.25
done
! kill -0 "${OLD_GUI_PID}" 2>/dev/null
! kill -0 "${OLD_DAEMON_PID}" 2>/dev/null

NEW_GUI_PID="$(pgrep -f '/Applications/Valid Team.app/Contents/MacOS/ValidTeam' | head -n 1 || true)"
NEW_DAEMON_PIDS="$(pgrep -f '/Applications/Valid Team.app/Contents/Resources/bin/vteam' || true)"
NEW_DAEMON_COUNT="$(printf '%s\n' "${NEW_DAEMON_PIDS}" | grep -cE '^[0-9]+$' || true)"
NEW_DAEMON_PID="$(printf '%s\n' "${NEW_DAEMON_PIDS}" | head -n 1)"
test -n "${NEW_GUI_PID}" && test -n "${NEW_DAEMON_PID}"
test "${NEW_GUI_PID}" != "${OLD_GUI_PID}"
test "${NEW_DAEMON_PID}" != "${OLD_DAEMON_PID}"
test "${NEW_DAEMON_COUNT}" -eq 1

test "$(shasum -a 256 "${SEC_TOML}" | awk '{print $1}')" = "${SEC_SHA_BEFORE}"
PROJ_SHA_AFTER="$(shasum -a 256 "${PROJECT_TOML}" | awk '{print $1}')"
if [ "${PROJ_SHA_AFTER}" != "${PROJ_SHA_BEFORE}" ]; then
  python3 - "${PROJ_TOML_BEFORE}" "${PROJECT_TOML}" <<'PYEOF'
import ast, pathlib, sys
try:
    import tomllib
except ImportError:
    tomllib = None

def parse_toml(raw):
    if tomllib is not None:
        return tomllib.loads(raw)
    doc = {}
    cur = doc
    for raw_line in raw.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line == "[[role]]":
            cur = {}
            doc.setdefault("role", []).append(cur)
            continue
        if "=" not in line:
            raise ValueError(f"unsupported TOML line: {line}")
        k, v = [p.strip() for p in line.split("=", 1)]
        if v == "true":
            val = True
        elif v == "false":
            val = False
        elif v.startswith('"') or v.startswith("["):
            val = ast.literal_eval(v)
        else:
            val = v
        cur[k] = val
    return doc

def norm(v):
    return v.isoformat() if hasattr(v, "isoformat") else v

b = parse_toml(pathlib.Path(sys.argv[1]).read_text("utf-8"))
a = parse_toml(pathlib.Path(sys.argv[2]).read_text("utf-8"))
if b.get("browser_skills_seeded", False) is not False or a.get("browser_skills_seeded") is not True:
    raise SystemExit(f"Clean-VM OTA Assertion 4 failed: unexpected project.toml mutation (seeded {b.get('browser_skills_seeded')!r} -> {a.get('browser_skills_seeded')!r})")
b_top = {k: norm(v) for k, v in b.items() if k not in ("role", "browser_skills_seeded")}
a_top = {k: norm(v) for k, v in a.items() if k not in ("role", "browser_skills_seeded")}
if b_top != a_top:
    raise SystemExit(f"Clean-VM OTA Assertion 4 failed: project.toml top-level metadata drifted: {b_top!r} != {a_top!r}")
b_roles, a_roles = b.get("role", []), a.get("role", [])
if len(b_roles) != len(a_roles):
    raise SystemExit(f"Clean-VM OTA Assertion 4 failed: project.toml role count drifted: {len(b_roles)} != {len(a_roles)}")
for idx, (br, ar) in enumerate(zip(b_roles, a_roles)):
    br_o = {k: norm(v) for k, v in br.items() if k != "skills"}
    ar_o = {k: norm(v) for k, v in ar.items() if k != "skills"}
    if br_o != ar_o:
        raise SystemExit(f"Clean-VM OTA Assertion 4 failed: project.toml role[{idx}] metadata drifted")
    bs, as_ = list(br.get("skills", [])), list(ar.get("skills", []))
    if (set(bs) - set(as_)) or not (set(as_) - set(bs)).issubset({"\u6d4f\u89c8\u5668\u64cd\u63a7"}) or len(as_) != len(set(as_)):
        raise SystemExit(f"Clean-VM OTA Assertion 4 failed: project.toml role[{idx}] skills drifted: {bs!r} -> {as_!r}")
print("    [Clean-VM macOS OTA] project.toml verified: exact v1.3.4 one-shot browser_skills_seeded migration (all metadata & roles preserved)")
PYEOF
fi
test "$(curl -sS -o /dev/null -w '%{http_code}' "${BASE_URL}/projects/${PROJECT_ENC}")" = "200"
SQLITE_CHECK="$(/usr/bin/sqlite3 "${STATE_DB}" "PRAGMA busy_timeout=15000; PRAGMA integrity_check;" | tail -n 1 | tr -d '\r\n')"
test "${SQLITE_CHECK}" = "ok"

# Cleanly stop upgraded B & remove temporary OTA verification data so Stage 5 6-stage LLM GUI E2E starts fresh
stop_live_apps
rm -rf "${PROJECT_DIR}" "${SEC_TOML}"
QUARANTINE_VAL="0081;67300000;Safari;12345678-1234-1234-1234-1234567890AB"
xattr -w com.apple.quarantine "${QUARANTINE_VAL}" "${APP_PATH}"

echo "MAC_CLEAN_OTA_E2E_OK from=${PREV_TAG} to=${TARGET_VERSION}"
