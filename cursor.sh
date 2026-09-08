#!/usr/bin/env bash
# cursor.sh — Wire Cursor IDE to OpenRouter's dedicated /api/v1/cursor endpoint.
# Usage: oc cursor [setup|apply|usage|probe|models]
#
# Official docs: https://openrouter.ai/docs/cookbook/coding-agents/cursor-integration
# The generic https://openrouter.ai/api/v1 endpoint does NOT handle Cursor tool calls.

set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/common.sh
source "$REPO/lib/common.sh"

ENV_FILE="${REPO}/.env"
oc_export_env_file "$ENV_FILE"

API_KEY="${OPENROUTER_API_KEY:-}"
MGMT_KEY="${OPENROUTER_MGMT_KEY:-}"
SPEC="$REPO/cursor-openrouter.json"
SETTINGS="${CURSOR_SETTINGS:-$HOME/Library/Application Support/Cursor/User/settings.json}"

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_b=$'\033[36m'; c_0=$'\033[0m'
ok(){ printf "  ${c_g}✓${c_0} %s\n" "$*"; }
opt(){ printf "  ${c_y}⚠${c_0} %s\n" "$*"; }
bad(){ printf "  ${c_r}✗${c_0} %s\n" "$*"; }
info(){ printf "  ${c_b}•${c_0} %s\n" "$*"; }

ENDPOINT="$(python3 -c "import json; print(json.load(open('$SPEC'))['endpoint'])")"
DEFAULT_MODEL="$(python3 -c "import json; print(json.load(open('$SPEC'))['default_model'])")"
SMALL_MODEL="$(python3 -c "import json; print(json.load(open('$SPEC'))['small_model'])")"

cmd="${1:-setup}"
shift || true
APPLY_NOW=0
AFTER_QUIT=0
for _arg in "$@"; do
  case "$_arg" in
    --now) APPLY_NOW=1 ;;
    --after-quit|--wait) AFTER_QUIT=1 ;;
  esac
done

LOCK_DIR="${HOME}/.opencode-backups"
LOCK_FILE="${LOCK_DIR}/cursor-apply-after-quit.pid"
LOCK_LOG="${LOCK_DIR}/cursor-apply-after-quit.log"

cursor_running() {
  python3 - <<'PY'
import subprocess, sys
needle = "/Applications/Cursor.app/Contents/MacOS/Cursor"
out = subprocess.check_output(["ps", "-axo", "command="], text=True)
for line in out.splitlines():
    cmd = line.strip()
    if cmd == needle or cmd.startswith(needle + " "):
        sys.exit(0)
sys.exit(1)
PY
}

wait_cursor_quit() {
  if ! cursor_running; then
    return 0
  fi
  opt "Cursor is running — waiting for a full quit (Cmd+Q). Reload Window is not enough."
  python3 - <<'PY'
import subprocess, sys, time
needle = "/Applications/Cursor.app/Contents/MacOS/Cursor"

def running():
    out = subprocess.check_output(["ps", "-axo", "command="], text=True)
    for line in out.splitlines():
        cmd = line.strip()
        if cmd == needle or cmd.startswith(needle + " "):
            return True
    return False

deadline = time.time() + 1800
while running():
    if time.time() > deadline:
        sys.exit(2)
    time.sleep(2)
time.sleep(3)
PY
  local st=$?
  if [[ "$st" -eq 2 ]]; then
    bad "timed out waiting for Cursor to quit (30m)"
    return 1
  fi
  if [[ "$st" -ne 0 ]]; then
    bad "wait helper failed (exit $st)"
    return 1
  fi
  ok "Cursor exited — writing model store"
}

schedule_after_quit() {
  mkdir -p "$LOCK_DIR"
  if [[ -f "$LOCK_FILE" ]]; then
    local old
    old="$(cat "$LOCK_FILE" 2>/dev/null || true)"
    if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
      info "already waiting on quit (pid $old) — log: $LOCK_LOG"
      return 0
    fi
  fi
  nohup "$REPO/cursor.sh" apply --after-quit >>"$LOCK_LOG" 2>&1 &
  echo $! >"$LOCK_FILE"
  ok "queued inject after Cmd+Q (pid $!, log $LOCK_LOG)"
}

print_setup() {
  echo -e "${c_b}═══ Cursor + OpenRouter ═══${c_0}"
  echo ""
  info "Docs: https://openrouter.ai/docs/cookbook/coding-agents/cursor-integration"
  info "Endpoint (required): $ENDPOINT"
  echo ""
  echo "  1. Cursor Settings → Models → API Keys"
  echo "  2. Enable OpenAI API Key → paste sk-or-... (never commit it)"
  echo "  3. Enable Override OpenAI Base URL →"
  echo "       $ENDPOINT"
  echo "  4. + Add model for each id below, then pick $DEFAULT_MODEL in Agent"
  echo ""
  python3 -c "
import json
d=json.load(open('$SPEC'))
print('  Models to add:')
for m in d['models']:
    mark = '  (default)' if m==d['default_model'] else ('  (small)' if m==d['small_model'] else '')
    print(f'    {m}{mark}')
print()
for n in d['notes']:
    print(f'  • {n}')
"
  echo ""
  echo "  Apply settings.json + inject models + encrypted sk-or- key:"
  echo "    oc cursor apply"
  echo "  Fully quit Cursor first (Cmd+Q). Reload Window flushes the old"
  echo "  in-memory model list and undoes the inject."
}

check_settings() {
  if [[ ! -f "$SETTINGS" ]]; then
    opt "Cursor settings.json not found: $SETTINGS"
    return 1
  fi
  python3 - "$SETTINGS" "$ENDPOINT" "$DEFAULT_MODEL" <<'PY'
import sys, re
path, endpoint, model = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
def grab(key):
    m = re.search(rf'"{re.escape(key)}"\s*:\s*"([^"]*)"', text)
    return m.group(1) if m else None
base = grab("openai.baseUrl")
chat = grab("cursor.chat.defaultModel") or grab("openai.model")
density = grab("cursor.composer.conversationDensity")
ok = True
if base == endpoint:
    print(f"OK base {base}")
else:
    print(f"BAD base {base!r} want {endpoint}")
    ok = False
if chat == model:
    print(f"OK model {chat}")
else:
    print(f"WARN model {chat!r} want {model}")
if density == "compact":
    print("OK density compact")
else:
    print(f"WARN density {density!r} want compact")
sys.exit(0 if ok else 2)
PY
}

apply_settings() {
  if [[ ! -f "$SETTINGS" ]]; then
    bad "Cursor settings.json not found: $SETTINGS"
    exit 1
  fi
  python3 - "$SETTINGS" "$ENDPOINT" "$DEFAULT_MODEL" "$SMALL_MODEL" <<'PY'
import os, re, shutil, sys
path, endpoint, model, small = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
orig = text

def repl_or_insert(key, value, text):
    pat = rf'("{re.escape(key)}"\s*:\s*")[^"]*(")'
    if re.search(pat, text):
        return re.sub(pat, rf'\1{value}\2', text, count=1)
    # insert after openai.baseUrl block if present, else at top of object
    needle = '"openai.baseUrl"'
    if needle in text:
        return text  # key missing but sibling exists — append near top
    return text.replace("{", '{\n  "%s": "%s",' % (key, value), 1)

text = repl_or_insert("openai.baseUrl", endpoint, text)
text = repl_or_insert("openai.model", model, text)
text = repl_or_insert("cursor.chat.defaultModel", model, text)
text = repl_or_insert("cursor.composer.defaultModel", model, text)
text = repl_or_insert("cursor.composer.conversationDensity", "compact", text)

# Keep comment accurate
text = text.replace(
    "// Cursor / AI — Strix gateway (api.strixgate.dev)",
    "// Cursor / AI — OpenRouter dedicated Cursor endpoint",
)
text = text.replace(
    "// Override OpenAI Base URL → all OpenAI-format traffic goes through Strix.",
    "// Override OpenAI Base URL → OpenRouter /api/v1/cursor (Cursor tool format).",
)
text = text.replace("strix-auto", model)
text = text.replace("https://api.strixgate.dev/v1", endpoint)

if text == orig:
    print("unchanged")
    sys.exit(0)

bak = path + ".bak.opencode"
shutil.copy2(path, bak)
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as f:
    f.write(text)
os.replace(tmp, path)
print("updated")
print(bak)
PY
}

# Write OpenRouter models + encrypted sk-or- key into Cursor's persistent store.
apply_cursor_state() {
  if [[ -z "$API_KEY" ]]; then
    bad "OPENROUTER_API_KEY not set in .env"
    return 1
  fi
  python3 - "$SPEC" "$API_KEY" "$ENDPOINT" "$DEFAULT_MODEL" <<'PY'
import json, os, sqlite3, subprocess, sys, time
from hashlib import pbkdf2_hmac
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding

spec_path, api_key, endpoint, default_model = sys.argv[1:5]
models = json.load(open(spec_path))["models"]
db = os.path.expanduser("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
STORE = "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
SECRET = "secret://cursorAuth/openAIKey"

pw = subprocess.check_output(
    ["security", "find-generic-password", "-w", "-s", "Cursor Safe Storage", "-a", "Cursor Key"],
    text=True,
).strip()
aes_key = pbkdf2_hmac("sha1", pw.encode(), b"saltysalt", 1003, dklen=16)
iv = b" " * 16

def encrypt(plaintext: str) -> dict:
    padder = padding.PKCS7(128).padder()
    padded = padder.update(plaintext.encode("utf-8")) + padder.finalize()
    enc = Cipher(algorithms.AES(aes_key), modes.CBC(iv)).encryptor()
    ct = enc.update(padded) + enc.finalize()
    blob = b"v10" + ct
    return {"type": "Buffer", "data": list(blob)}

def decrypt(obj) -> str:
    data = bytes(obj["data"])
    assert data[:3] == b"v10"
    dec = Cipher(algorithms.AES(aes_key), modes.CBC(iv)).decryptor()
    pt = dec.update(data[3:]) + dec.finalize()
    unpadder = padding.PKCS7(128).unpadder()
    return (unpadder.update(pt) + unpadder.finalize()).decode("utf-8")

con = sqlite3.connect(db, timeout=30)
cur = con.cursor()
row = cur.execute("SELECT value FROM ItemTable WHERE key=?", (STORE,)).fetchone()
if not row:
    print("FAIL missing Cursor persistent storage")
    sys.exit(1)
state = json.loads(row[0])
bak_dir = os.path.expanduser("~/.opencode-backups")
os.makedirs(bak_dir, exist_ok=True)
bak = os.path.join(bak_dir, f"cursor-applicationUser-{time.strftime('%Y%m%d-%H%M%S')}.json")
open(bak, "w").write(row[0])

state["useOpenAIKey"] = True
state["openAIBaseUrl"] = endpoint
ai = state.setdefault("aiSettings", {})
ai["userAddedModels"] = list(models)
enabled = [m for m in (ai.get("modelOverrideEnabled") or []) if not str(m).startswith("strix-")]
for m in models:
    if m not in enabled:
        enabled.append(m)
ai["modelOverrideEnabled"] = enabled
disabled = [m for m in (ai.get("modelOverrideDisabled") or []) if m not in models]
ai["modelOverrideDisabled"] = disabled

cfg = ai.setdefault("modelConfig", {})
for slot in ("composer", "background-composer", "cmd-k", "plan-execution", "quick-agent"):
    block = cfg.setdefault(slot, {})
    if slot == "cmd-k":
        continue
    block["modelName"] = default_model
    block["selectedModels"] = [{"modelId": default_model, "parameters": []}]
    if slot == "background-composer":
        block["maxMode"] = False

cur.execute(
    "INSERT INTO ItemTable(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    (STORE, json.dumps(state, separators=(",", ":"))),
)
cur.execute(
    "INSERT INTO ItemTable(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
    (SECRET, json.dumps(encrypt(api_key), separators=(",", ":"))),
)
for k, payload in (
    ("cursor/initialModelAppliedConfig", {"selectedModels": [{"modelId": default_model, "parameters": []}], "maxMode": False}),
    ("cursor/applicationOpenModelAppliedConfig", {"selectedModels": [{"modelId": default_model, "parameters": []}], "maxMode": False}),
):
    cur.execute(
        "INSERT INTO ItemTable(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        (k, json.dumps(payload)),
    )
con.commit()

# verify
state2 = json.loads(cur.execute("SELECT value FROM ItemTable WHERE key=?", (STORE,)).fetchone()[0])
sec = json.loads(cur.execute("SELECT value FROM ItemTable WHERE key=?", (SECRET,)).fetchone()[0])
got = decrypt(sec)
ok_key = got == api_key and got.startswith("sk-or-")
ok_models = state2.get("aiSettings", {}).get("userAddedModels") == models
ok_url = state2.get("openAIBaseUrl") == endpoint
ok_flag = state2.get("useOpenAIKey") is True
print(f"models {len(models)} key={ok_key} url={ok_url} byok={ok_flag} added={ok_models}")
print(bak)
if not (ok_key and ok_url and ok_flag and ok_models):
    sys.exit(1)
PY
}

probe_all() {
  if [[ -z "$API_KEY" ]]; then
    bad "OPENROUTER_API_KEY not set"
    exit 1
  fi
  echo -e "${c_b}═══ Probe all Cursor models via $ENDPOINT ═══${c_0}"
  echo ""
  python3 - "$API_KEY" "$ENDPOINT" "$SPEC" <<'PY'
import json, sys, urllib.request, concurrent.futures
key, url, spec = sys.argv[1:4]
models = json.load(open(spec))["models"]
endpoint = url.rstrip("/") + "/chat/completions"

def ping(model):
    payload = json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": "Reply with the single word pong."}],
        "max_tokens": 8,
        "temperature": 0,
    }).encode()
    req = urllib.request.Request(
        endpoint,
        data=payload,
        headers={
            "Authorization": f"Bearer {key}",
            "Content-Type": "application/json",
            "HTTP-Referer": "https://cursor.com",
            "X-OpenRouter-Title": "Cursor",
            "X-Title": "Cursor",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read())
            code = resp.status
        usage = data.get("usage") or {}
        return model, code, (data.get("model") or model), usage.get("prompt_tokens"), usage.get("completion_tokens"), None
    except Exception as e:
        code = getattr(e, "code", None)
        return model, code or "ERR", "", None, None, str(e)[:160]

ok = 0
with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
    rows = list(pool.map(ping, models))
for model, code, routed, pt, ct, err in rows:
    if code == 200:
        ok += 1
        print(f"  OK  {model}  (routed {routed}  tok {pt}/{ct})")
    else:
        print(f"  FAIL {model}  {code}  {err}")
print()
print(f"  {ok}/{len(models)} models live on /api/v1/cursor")
sys.exit(0 if ok == len(models) else 1)
PY
}

probe_cursor() {
  if [[ -z "$API_KEY" ]]; then
    bad "OPENROUTER_API_KEY not set"
    exit 1
  fi
  echo -e "${c_b}═══ Probe $ENDPOINT ═══${c_0}"
  echo ""
  python3 - "$API_KEY" "$ENDPOINT" "$DEFAULT_MODEL" <<'PY'
import json, sys, urllib.request
key, url, model = sys.argv[1:4]
payload = json.dumps({
    "model": model,
    "messages": [{"role": "user", "content": "Reply with the single word pong."}],
    "max_tokens": 8,
    "temperature": 0,
}).encode()
req = urllib.request.Request(
    url.rstrip("/") + "/chat/completions",
    data=payload,
    headers={
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
        "HTTP-Referer": "https://cursor.com",
        "X-OpenRouter-Title": "Cursor",
        "X-Title": "Cursor",
    },
    method="POST",
)
try:
    with urllib.request.urlopen(req, timeout=45) as resp:
        raw = resp.read()
        code = resp.status
        hdrs = dict(resp.headers)
except Exception as e:
    print(f"FAIL {e}")
    sys.exit(1)
data = json.loads(raw)
msg = ((data.get("choices") or [{}])[0].get("message") or {})
txt = (msg.get("content") or "").strip().replace("\n", " ")
usage = data.get("usage") or {}
print(f"HTTP {code}  model={data.get('model') or model}")
print(f"reply: {txt[:120] or '(empty — tool-call-only is ok)'}")
print(f"tokens: prompt={usage.get('prompt_tokens')} completion={usage.get('completion_tokens')}")
gen = hdrs.get("X-Generation-Id") or hdrs.get("x-generation-id")
if gen:
    print(f"generation: {gen}")
PY
}

show_usage() {
  echo -e "${c_b}═══ OpenRouter usage (last 30 days) ═══${c_0}"
  echo ""
  if [[ -z "$MGMT_KEY" ]]; then
    opt "OPENROUTER_MGMT_KEY not set — showing credits only"
    if [[ -z "$API_KEY" ]]; then
      bad "OPENROUTER_API_KEY not set"
      exit 1
    fi
    curl -s -H "Authorization: Bearer $API_KEY" https://openrouter.ai/api/v1/credits | python3 -c "
import json,sys
d=json.load(sys.stdin)['data']
print(f\"  credits remaining: \${d['total_credits']-d['total_usage']:.2f}\")
print(f\"  usage total:      \${d['total_usage']:.2f}\")
print('  Tip: set OPENROUTER_MGMT_KEY to break down by model (oc cursor usage)')
"
    return
  fi
  curl -s -H "Authorization: Bearer $MGMT_KEY" https://openrouter.ai/api/v1/activity | python3 -c "
import json, sys
from collections import defaultdict
raw = json.load(sys.stdin)
rows = raw.get('data') or []
if not rows:
    print('  no activity rows (management key may lack analytics scope)')
    sys.exit(0)
by_model = defaultdict(lambda: {'req':0,'prompt':0,'comp':0,'reason':0,'usd':0.0})
days = set()
for r in rows:
    m = r.get('model') or '?'
    days.add(r.get('date'))
    b = by_model[m]
    b['req'] += int(r.get('requests') or 0)
    b['prompt'] += int(r.get('prompt_tokens') or 0)
    b['comp'] += int(r.get('completion_tokens') or 0)
    b['reason'] += int(r.get('reasoning_tokens') or 0)
    b['usd'] += float(r.get('usage') or 0)
tot_p = sum(v['prompt'] for v in by_model.values())
tot_c = sum(v['comp'] for v in by_model.values())
tot_r = sum(v['reason'] for v in by_model.values())
tot_u = sum(v['usd'] for v in by_model.values())
tot_n = sum(v['req'] for v in by_model.values())
print(f'  days: {len(days)}  requests: {tot_n:,}  spend: \${tot_u:.2f}')
print(f'  tokens: prompt={tot_p:,}  completion={tot_c:,}  reasoning={tot_r:,}')
print()
print(f'  {\"model\":<42} {\"req\":>6} {\"prompt\":>12} {\"compl\":>10} {\"reason\":>10} {\"usd\":>8}')
for m, v in sorted(by_model.items(), key=lambda kv: kv[1]['usd'], reverse=True)[:20]:
    print(f'  {m:<42} {v[\"req\"]:>6} {v[\"prompt\"]:>12,} {v[\"comp\"]:>10,} {v[\"reason\"]:>10,} {v[\"usd\"]:>8.2f}')
print()
print('  Cursor vs OpenCode: OpenRouter attributes Cursor traffic when the')
print('  client hits /api/v1/cursor. Use a dedicated key labeled Cursor if')
print('  you want a clean per-app split in oc admin keys.')
"
}

case "$cmd" in
  -h|--help|help)
    cat <<HELP
oc cursor — Cursor IDE + OpenRouter

  setup    Print the official /api/v1/cursor wiring (default)
  apply           Wire settings.json + inject models + OpenRouter sk-or- key
                  (if Cursor is running, queues the sqlite write until Cmd+Q)
  apply --wait    Block until Cursor quits, then inject
  apply --now     Write sqlite even while Cursor is running (will be overwritten)
  status          Show models currently stored in Cursor sqlite
  usage           OpenRouter activity by model (management key)
  probe           Tiny live call (default model)
  probe-all       Live call every pinned model
  models          Print pinned model ids
  check           Report whether settings.json already matches

Docs: https://openrouter.ai/docs/cookbook/coding-agents/cursor-integration
HELP
    ;;
  setup|info)
    print_setup
    echo ""
    echo -e "${c_b}── Current Cursor settings ──${c_0}"
    if check_settings; then
      ok "settings.json already uses the Cursor OpenRouter endpoint"
    else
      opt "run: oc cursor apply"
    fi
    ;;
  check)
    check_settings && ok "Cursor OpenRouter endpoint is set" || { opt "mismatch — oc cursor apply"; exit 2; }
    ;;
  apply)
    result="$(apply_settings)"
    if [[ "$result" == unchanged* ]]; then
      ok "settings.json already current"
    else
      ok "updated $SETTINGS"
      info "backup written next to settings.json (.bak.opencode)"
    fi
    echo ""
    if [[ "$AFTER_QUIT" -eq 1 ]]; then
      wait_cursor_quit || exit 1
    elif cursor_running && [[ "$APPLY_NOW" -eq 0 ]]; then
      opt "Cursor is open. A live session flushes Strix models over sqlite on quit/reload."
      schedule_after_quit
      echo ""
      opt "Fully quit Cursor (Cmd+Q), then reopen. Do not Reload Window."
      opt "Select $DEFAULT_MODEL in Agent — not Composer (Composer ignores BYOK)."
      exit 0
    fi
    info "injecting OpenRouter models + encrypted sk-or- key into Cursor"
    if out="$(apply_cursor_state)"; then
      ok "$out"
    else
      bad "failed to write Cursor model store"
      printf '%s\n' "$out"
      exit 1
    fi
    rm -f "$LOCK_FILE"
    check_settings || true
    echo ""
    probe_all
    echo ""
    opt "Reopen Cursor now. Pick $DEFAULT_MODEL in Agent — not Composer (Composer ignores BYOK)."
    ;;
  status)
    python3 - <<'PY'
import json, os, sqlite3
db = os.path.expanduser("~/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
STORE = "src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
SECRET = "secret://cursorAuth/openAIKey"
con = sqlite3.connect(db)
cur = con.cursor()
row = cur.execute("SELECT value FROM ItemTable WHERE key=?", (STORE,)).fetchone()
sec = cur.execute("SELECT value FROM ItemTable WHERE key=?", (SECRET,)).fetchone()
state = json.loads(row[0]) if row else {}
ai = state.get("aiSettings") or {}
print("useOpenAIKey", state.get("useOpenAIKey"))
print("openAIBaseUrl", state.get("openAIBaseUrl"))
print("encrypted_key", "yes" if sec else "no")
print("userAddedModels:")
for m in ai.get("userAddedModels") or []:
    print(" ", m)
PY
    ;;
  probe-all|probeall)
    probe_all
    ;;
  usage|activity)
    show_usage
    ;;
  probe|ping)
    probe_cursor
    ;;
  models)
    python3 -c "
import json
d=json.load(open('$SPEC'))
print(d['endpoint'])
print(d['default_model'])
for m in d['models']:
    print(m)
"
    ;;
  *)
    bad "unknown subcommand: $cmd"
    echo "  oc cursor [setup|apply|status|usage|probe|probe-all|models|check]"
    exit 2
    ;;
esac
