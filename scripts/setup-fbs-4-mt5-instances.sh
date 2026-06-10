#!/bin/bash
# Four ISOLATED FBS MT5 instances, each in its OWN Wine prefix.
#
# Why its own prefix: terminals that share one Wine prefix also share one
# wineserver process -- closing/killing one closes them ALL ("MT5 self-close").
# One prefix per instance keeps them fully independent.
#
# Layout created:
#   net.metaquotes.wine.metatrader5-fbs1 .. -fbs4
#     drive_c/Program Files/MetaTrader 5-FBS-N/terminal64.exe  (+ portable.txt)
set -euo pipefail

APP_SUPPORT="${HOME}/Library/Application Support"
ACCOUNTS_DIR="${APP_SUPPORT}/mt5-fbs-accounts"

# Source prefix to clone from (the official MetaTrader 5.app's prefix).
SRC_PREFIX=""
for cand in "${APP_SUPPORT}/net.metaquotes.wine.MetaTrader5" \
            "${APP_SUPPORT}/net.metaquotes.wine.metatrader5"; do
  if [[ -f "${cand}/drive_c/Program Files/MetaTrader 5/terminal64.exe" ]]; then
    SRC_PREFIX="${cand}"; break
  fi
done

mkdir -p "${ACCOUNTS_DIR}"

for n in 1 2 3 4; do
  dst_prefix="${APP_SUPPORT}/net.metaquotes.wine.metatrader5-fbs${n}"
  dst_term="${dst_prefix}/drive_c/Program Files/MetaTrader 5-FBS-${n}/terminal64.exe"

  if [[ -f "${dst_term}" ]]; then
    echo "OK: instance ${n} already present (${dst_prefix##*/})"
    continue
  fi

  if [[ -z "${SRC_PREFIX}" ]]; then
    echo "Error: no source MT5 prefix found to clone instance ${n}."
    echo "       Install/run MetaTrader 5.app once so its Wine prefix exists, then re-run."
    exit 1
  fi

  echo "Cloning instance ${n} from ${SRC_PREFIX##*/} (APFS copy-on-write)..."
  cp -Rc "${SRC_PREFIX}" "${dst_prefix}"
  # Rename the MT5 program folder so each instance is uniquely identifiable.
  mv "${dst_prefix}/drive_c/Program Files/MetaTrader 5" \
     "${dst_prefix}/drive_c/Program Files/MetaTrader 5-FBS-${n}"
  touch "${dst_prefix}/drive_c/Program Files/MetaTrader 5-FBS-${n}/portable.txt"
  echo "Created ${dst_prefix##*/}"
done

# Optional per-account auto-login config templates -- one UNIQUE login each.
for n in 1 2 3 4; do
  ex="${ACCOUNTS_DIR}/account${n}.conf.example"
  if [[ ! -f "${ex}" ]]; then
    cat > "${ex}" <<EOF
# Rename to account${n}.conf and set a UNIQUE FBS login (do NOT reuse the same
# login across windows -- the broker allows only one session per login and will
# disconnect the others).
# chmod 600 account${n}.conf
LOGIN=
PASSWORD=
SERVER=FBS-Real
EOF
  fi
done

cat > "${ACCOUNTS_DIR}/README.txt" <<'EOF'
FBS -- 4 MT5 instances (accounts 1-4), each in its own Wine prefix.

Desktop: double-click "FBS.app" to open all 4 terminals.

IMPORTANT: log in to a DIFFERENT account in each window. Reusing one login
makes the broker kick the other windows off (repeated disconnects).

Optional auto-login:
  cp account1.conf.example account1.conf
  edit LOGIN, PASSWORD, SERVER
  chmod 600 account1.conf
  (repeat for account2 .. account4)

Prefixes:
  net.metaquotes.wine.metatrader5-fbs1 .. -fbs4
EOF

echo ""
echo "Done. Use FBS.app on Desktop to launch all 4 (one login per window)."
