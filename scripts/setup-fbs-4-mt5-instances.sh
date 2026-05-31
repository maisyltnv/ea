#!/bin/bash
# Four isolated FBS MT5 copies (APFS clone) — one login per instance.
set -euo pipefail

WINE_PREFIX="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5"
PF="${WINE_PREFIX}/drive_c/Program Files"
SRC="${PF}/MetaTrader 5"
ACCOUNTS_DIR="${HOME}/Library/Application Support/mt5-fbs-accounts"

if [[ ! -f "${SRC}/terminal64.exe" ]]; then
  echo "Error: MetaTrader 5 not found at ${SRC}"
  exit 1
fi

mkdir -p "${ACCOUNTS_DIR}"

for n in 1 2 3 4; do
  dst="${PF}/MetaTrader 5-FBS-${n}"
  if [[ -f "${dst}/terminal64.exe" ]]; then
    echo "OK: already exists ${dst}"
    continue
  fi
  echo "Cloning instance ${n} (APFS copy-on-write)..."
  cp -Rc "${SRC}" "${dst}"
  touch "${dst}/portable.txt"
  echo "Created ${dst}"
done

for n in 1 2 3 4; do
  ex="${ACCOUNTS_DIR}/account${n}.conf.example"
  if [[ ! -f "${ex}" ]]; then
    cat > "${ex}" <<EOF
# Rename to account${n}.conf and set your FBS login (optional).
# chmod 600 account${n}.conf
LOGIN=
PASSWORD=
SERVER=FBS-Real
EOF
  fi
done

cat > "${ACCOUNTS_DIR}/README.txt" <<'EOF'
FBS — 4 MT5 instances (accounts 1–4)

Desktop: double-click "FBS.app" to open all 4 terminals.

First time per window: log in with a different FBS account (or use accountN.conf).

Optional auto-login:
  cp account1.conf.example account1.conf
  edit LOGIN, PASSWORD, SERVER
  chmod 600 account1.conf
  (repeat for account2 … account4)

Folders:
  Program Files/MetaTrader 5-FBS-1 … MetaTrader 5-FBS-4
EOF

echo ""
echo "Done. Use FBS.app on Desktop to launch all 4."
