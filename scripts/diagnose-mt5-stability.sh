#!/bin/bash
# Diagnose why MT5 terminals close unexpectedly on macOS (Wine).
# Auto-discovers every net.metaquotes.wine* prefix, reads today's logs,
# tells crash vs clean exit, and flags the two real causes of self-close:
#   1) the SAME login used in more than one terminal (broker kicks the others)
#   2) more than one terminal sharing ONE Wine prefix (shared wineserver)
set -euo pipefail

APP_SUPPORT="${HOME}/Library/Application Support"
TODAY="$(date +%Y%m%d)"

echo "=== MT5 Stability Diagnostic ($(date '+%Y-%m-%d %H:%M')) ==="
echo

# 1. Running terminals -------------------------------------------------------
echo "--- Running terminals ---"
if pgrep -f terminal64.exe >/dev/null 2>&1; then
  pgrep -lf terminal64.exe | sed 's/^/   /'
else
  echo "   [INFO] No MT5 terminal running right now"
fi
echo

# 2. Wine prefixes found -----------------------------------------------------
echo "--- Wine prefixes ---"
shopt -s nullglob
prefixes=( "${APP_SUPPORT}"/net.metaquotes.wine* )
shopt -u nullglob
if [[ ${#prefixes[@]} -eq 0 ]]; then
  echo "   [FAIL] No net.metaquotes.wine* prefix found under Application Support"
  exit 1
fi
for p in "${prefixes[@]}"; do echo "   ${p##*/}"; done
echo

# 3. Memory (macOS: "free" alone is misleading; count free+inactive+speculative)
vm_stat | awk '
  /page size of/      {gsub(/[^0-9]/,"",$8); ps=$8}
  /Pages free/        {gsub(/\./,"",$3); f=$3}
  /Pages inactive/    {gsub(/\./,"",$3); i=$3}
  /Pages speculative/ {gsub(/\./,"",$3); s=$3}
  END {if(ps=="")ps=4096; printf "[INFO] Available RAM: %.1f GB  (keep 6+ GB free for 4 terminals)\n", (f+i+s)*ps/1024/1024/1024}'
echo

# 4. Per-install log analysis + cross-prefix duplicate-login check ------------
python3 - "$TODAY" "${prefixes[@]}" <<'PY'
import sys, pathlib, re

today = sys.argv[1]
prefixes = [pathlib.Path(p) for p in sys.argv[2:]]

def read_utf16(path):
    try:
        return path.read_bytes().decode("utf-16-le", errors="replace").replace("\x00", "")
    except Exception:
        return ""

login_map = {}   # account -> set(prefix tags)
offscreen = []
crash_suspects = []

print("--- Today's terminal logs (%s) ---" % today)
any_log = False
for pref in sorted(prefixes):
    tag = pref.name.split("metatrader5-")[-1] if "metatrader5-" in pref.name else pref.name
    for term_dir in sorted((pref / "drive_c/Program Files").glob("*")):
        log = term_dir / "logs" / (today + ".log")
        if not log.exists():
            continue
        text = read_utf16(log)
        lines = [l.strip() for l in text.split("\n") if l.strip()]
        if not lines:
            continue
        any_log = True
        starts   = [l for l in lines if "started for MetaQuotes" in l]
        exits0   = [l for l in lines if "exit with code 0" in l.lower() or "shutdown with 0" in l.lower()]
        exitsbad = [l for l in lines if re.search(r"exit with code [1-9]", l.lower())]
        # collect logins
        for m in re.finditer(r"'(\d+)': authorized on (\S+)", text):
            login_map.setdefault(m.group(1), set()).add(f"{tag}/{term_dir.name}")

        status = "CLEAN exit (code 0)" if exits0 and not exitsbad else \
                 ("NON-ZERO exit %s" % exitsbad[-1] if exitsbad else "running / no exit logged")
        print(f"   [{tag}] {term_dir.name}: {len(starts)} start(s), {len(exits0)} clean shutdown(s) -> {status}")
        # crash heuristic: multiple starts, no clean shutdown
        if len(starts) > 1 and not exits0:
            crash_suspects.append(f"{tag}/{term_dir.name} restarted {len(starts)}x with no clean shutdown")

if not any_log:
    print("   [INFO] No logs dated today; terminals may not have run yet today.")
print()

# 5. Duplicate-login check ---------------------------------------------------
print("--- One-login-per-window check ---")
dups = {acc: sorted(tags) for acc, tags in login_map.items() if len(tags) > 1}
if dups:
    print("   [FAIL] Same login used in multiple terminals -> broker kicks the others off:")
    for acc, tags in dups.items():
        print(f"          account {acc}: {', '.join(tags)}")
    print("   Fix: give each terminal a UNIQUE login (edit mt5-fbs-accounts/accountN.conf).")
else:
    if login_map:
        print("   [OK] Every login is used in only one terminal.")
    else:
        print("   [INFO] No authorizations found in today's logs.")
print()

# 6. Off-screen window check -------------------------------------------------
print("--- Window position check ---")
for pref in sorted(prefixes):
    tag = pref.name.split("metatrader5-")[-1] if "metatrader5-" in pref.name else pref.name
    for ini in (pref / "drive_c/Program Files").glob("*/config/terminal.ini"):
        text = read_utf16(ini)
        m = re.search(r"Left=(-?\d+).*?Top=(-?\d+)", text, re.DOTALL)
        if not m:
            continue
        left, top = int(m.group(1)), int(m.group(2))
        if top < 0 or left < -200:
            offscreen.append(f"{tag}/{ini.parts[-3]} (Left={left}, Top={top})")
if offscreen:
    print("   [FAIL] Off-screen window (app runs but looks closed):")
    for o in offscreen:
        print(f"          {o}")
    print("   Fix: bash scripts/fix-mt5-window-position.sh")
else:
    print("   [OK] All window positions on-screen (or no terminal.ini yet).")
print()

if crash_suspects:
    print("--- Possible crashes (started repeatedly, no clean shutdown) ---")
    for c in crash_suspects:
        print(f"   [WARN] {c}")
    print("   Check ~/Library/Logs/DiagnosticReports for terminal64/wine .ips files.")
    print()
PY

echo "=== Recommendations ==="
echo "1. Use a DIFFERENT broker login in every window (same login kicks the others off)."
echo "2. Run only ONE terminal per Wine prefix (terminals in one prefix share a wineserver"
echo "   and die together). The FBS Account 1-4 apps are already 1 terminal : 1 prefix."
echo "3. If a window is invisible: bash scripts/fix-mt5-window-position.sh"
echo "4. Keep 6+ GB RAM free before opening 4 terminals."
