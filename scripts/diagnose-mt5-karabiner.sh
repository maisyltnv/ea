#!/bin/bash
# Diagnose why MT5 copy/paste Karabiner rules are not working.
set -euo pipefail

echo "=== Karabiner MT5 Copy/Paste Diagnostic ==="
echo

# 1. Karabiner installed?
if [[ -d "/Applications/Karabiner-Elements.app" ]]; then
  echo "[OK] Karabiner-Elements installed"
else
  echo "[FAIL] Karabiner-Elements NOT installed"
  exit 1
fi

# 2. Karabiner running?
if pgrep -q Karabiner-Elements; then
  echo "[OK] Karabiner-Elements is running"
else
  echo "[WARN] Karabiner-Elements is NOT running — open it from Applications"
fi

if pgrep -q karabiner_console_user_server; then
  echo "[OK] karabiner_console_user_server daemon running"
else
  echo "[FAIL] karabiner_console_user_server NOT running — rules cannot work"
fi

# 3. Driver extension status from log
LOG="${HOME}/.local/share/karabiner/log/console_user_server.log"
if [[ -f "${LOG}" ]]; then
  if grep -q "driver_extension" "${LOG}" 2>/dev/null; then
    echo "[WARN] Karabiner setup still on 'driver_extension' step — Driver NOT fully enabled"
    echo "       → System Settings → General → Login Items & Extensions → Driver Extensions"
    echo "       → Enable: Karabiner-VirtualHIDDevice-Manager (or org.pqrs.Karabiner-DriverKit-VirtualHIDDevice)"
  fi
  if grep -q "core_service_client is connected" "${LOG}" 2>/dev/null; then
    echo "[OK] Karabiner core service connected"
  else
    echo "[WARN] Karabiner core service not connected yet"
  fi
else
  echo "[WARN] No Karabiner log yet — open Karabiner-Elements once"
fi

# 4. MT5 rules in config
python3 <<'PY'
import json, pathlib
p = pathlib.Path.home() / '.config/karabiner/karabiner.json'
if not p.exists():
    print('[FAIL] No karabiner.json')
else:
    d = json.load(open(p))
    for prof in d.get('profiles', []):
        if prof.get('selected'):
            rules = prof.get('complex_modifications', {}).get('rules', [])
            mt5 = [r for r in rules if 'MT5' in r.get('description', '')]
            if mt5:
                print(f'[OK] {len(mt5)} MT5 rule(s) enabled in config')
            else:
                print('[FAIL] No MT5 rules in karabiner.json')
            break
PY

# 5. MT5 running?
if pgrep -f terminal64.exe >/dev/null; then
  echo "[OK] MT5 (terminal64.exe) is running"
  lsappinfo list 2>/dev/null | grep -iE 'FBS|wine|meta' | head -6 | sed 's/^/       /'
else
  echo "[INFO] MT5 not running right now"
fi

echo
echo "=== What to do ==="
echo "1. Open Karabiner-Elements → follow the yellow/red setup banner"
echo "2. Enable Driver Extension in System Settings (required for key remapping!)"
echo "3. Restart Mac (or at least restart Karabiner + MT5)"
echo "4. Open Karabiner-EventViewer → Frontmost Application tab → click MT5 field"
echo "   Confirm bundle/file path matches our rules"
echo "5. Test Control+C in MT5 Take Profit field"
echo
echo "Run: open -a Karabiner-EventViewer"
