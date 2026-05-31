#!/bin/bash
# Install Karabiner rules so Control+C / Command+C copy works in MT5 (Wine) text fields.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_SRC="${SCRIPT_DIR}/mt5-wine-copy-paste-karabiner.json"
KARABINER_DIR="${HOME}/.config/karabiner"
ASSETS_DIR="${KARABINER_DIR}/assets/complex_modifications"
RULE_DST="${ASSETS_DIR}/mt5-wine-copy-paste.json"
KARABINER_JSON="${KARABINER_DIR}/karabiner.json"

python3 -m json.tool "${RULE_SRC}" >/dev/null
mkdir -p "${ASSETS_DIR}"
cp "${RULE_SRC}" "${RULE_DST}"
echo "✓ Copied rule to ${RULE_DST}"

# Enable rules directly in karabiner.json (works after Karabiner is installed once)
export RULE_SRC KARABINER_JSON
python3 <<'PY'
import json, os, pathlib

rule_src = pathlib.Path(os.environ["RULE_SRC"])
rules = json.loads(rule_src.read_text())["rules"]
config_path = pathlib.Path(os.environ["KARABINER_JSON"])

if config_path.exists():
    config = json.loads(config_path.read_text())
else:
    config = {
        "global": {
            "check_for_updates_on_startup": True,
            "show_in_menu_bar": True,
            "show_profile_name_in_menu_bar": False
        },
        "profiles": [{
            "name": "Default profile",
            "selected": True,
            "virtual_hid_keyboard": {"keyboard_type_v2": "ansi"},
            "devices": [],
            "complex_modifications": {"parameters": {}, "rules": []}
        }]
    }

for profile in config.get("profiles", []):
    if profile.get("selected"):
        cm = profile.setdefault("complex_modifications", {"parameters": {}, "rules": []})
        existing = cm.setdefault("rules", [])
        existing[:] = [r for r in existing if "MT5" not in r.get("description", "") and "MetaTrader" not in r.get("description", "")]
        existing.extend(rules)
        break
else:
    raise SystemExit("No selected profile in karabiner.json")

config_path.parent.mkdir(parents=True, exist_ok=True)
config_path.write_text(json.dumps(config, indent=4) + "\n")
print(f"✓ Enabled MT5 rules in {config_path}")
PY

if [[ ! -d "/Applications/Karabiner-Elements.app" && ! -d "/Applications/Karabiner-EventViewer.app" ]]; then
  echo
  echo "Karabiner-Elements is NOT installed yet (required for Control+C fix)."
  if command -v brew >/dev/null 2>&1; then
    echo "Opening installer — enter your Mac password when prompted:"
    brew install --cask karabiner-elements || true
  fi
  if [[ ! -d "/Applications/Karabiner-Elements.app" ]]; then
    echo
    echo "Install manually: https://karabiner-elements.pqrs.org/"
    echo "Then open Karabiner-Elements → grant Input Monitoring → restart MT5."
    exit 1
  fi
fi

echo
echo "Done. Next steps:"
echo "  1. Open Karabiner-Elements (Applications)"
echo "  2. Allow Input Monitoring + Accessibility if macOS asks"
echo "  3. Complex Modifications → confirm MT5 rules show as ENABLED"
echo "  4. Restart MT5, select Take Profit text, press Control+C or Command+C"
echo
echo "Tip: Until Karabiner runs, try Control+Insert on an external keyboard for copy."
