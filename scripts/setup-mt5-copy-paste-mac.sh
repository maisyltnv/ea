#!/bin/bash
# Fix MT5 (Wine) copy/paste keyboard shortcuts on macOS.
# MT5 is a Windows app under Wine — it expects Ctrl+C, not Cmd+C.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RULE_SRC="${SCRIPT_DIR}/mt5-wine-copy-paste-karabiner.json"
KARABINER_ASSETS="${HOME}/.config/karabiner/assets/complex_modifications"
RULE_DST="${KARABINER_ASSETS}/mt5-wine-copy-paste.json"

if [[ ! -f "${RULE_SRC}" ]]; then
  echo "Error: missing ${RULE_SRC}"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "Error: python3 is required to validate JSON"
  exit 1
fi

python3 -m json.tool "${RULE_SRC}" >/dev/null

if [[ ! -d "/Applications/Karabiner-Elements.app" ]]; then
  echo "Karabiner-Elements is not installed."
  if command -v brew >/dev/null 2>&1; then
    echo "Installing via Homebrew..."
    brew install --cask karabiner-elements
  else
    echo "Install manually: https://karabiner-elements.pqrs.org/"
    exit 1
  fi
fi

mkdir -p "${KARABINER_ASSETS}"
cp "${RULE_SRC}" "${RULE_DST}"
echo "Installed rule: ${RULE_DST}"

echo
echo "Next steps (one-time):"
echo "  1. Open Karabiner-Elements (grant Input Monitoring if macOS asks)"
echo "  2. Complex Modifications → Add rule"
echo "  3. Enable ONE of these (try the first rule first):"
echo "       a) 'Map Cmd+C/V/X/A to Ctrl+C/V/X/A'  (recommended)"
echo "       b) 'Swap Control and Command keys'     (if Control+C still fails)"
echo "  4. Restart MT5, select text in Take Profit field, try:"
echo "       - Command+C  (recommended with rule a)"
echo "       - Control+C  (physical ^ key; use rule b if needed)"
echo
echo "Optional macOS fix (helps Wine text fields):"
echo "  System Settings → Keyboard → Edit Input Sources"
echo "  Turn OFF 'Press and hold for accent marks'"
