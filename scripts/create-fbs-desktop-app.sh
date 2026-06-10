#!/bin/bash
# Creates FBS Account 1–4.app (one MT5 each) + FBS.app (opens all four).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP="${HOME}/Desktop"
WINE_PREFIX="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5"
MT5_APP="${DESKTOP}/MetaTrader 5.app"
ICON_SRC="${MT5_APP}/Contents/Resources/AppIcon.icns"
ACCOUNTS_DIR="${HOME}/Library/Application Support/mt5-fbs-accounts"

if [[ ! -x "${MT5_APP}/Contents/SharedSupport/wine/bin/wine" ]]; then
  echo "Error: MetaTrader 5.app must be on Desktop."
  exit 1
fi

"${SCRIPT_DIR}/setup-fbs-4-mt5-instances.sh"
"${SCRIPT_DIR}/fix-mt5-window-position.sh" || true

create_fbs_instance_app() {
  local n="$1"
  local app_name="FBS Account ${n}"
  local app_path="${DESKTOP}/${app_name}.app"
  local term_dir="MetaTrader 5-FBS-${n}"
  # Each instance lives in its OWN Wine prefix so terminals never share a
  # wineserver (shared wineserver = they all close together / self-close).
  local inst_prefix="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5-fbs${n}"
  local term_path="${inst_prefix}/drive_c/Program Files/${term_dir}/terminal64.exe"
  local bundle_id="net.metaquotes.wine.FBS.account${n}"

  if [[ ! -f "${term_path}" ]]; then
    echo "Error: missing ${term_path}"
    exit 1
  fi

  rm -rf "${app_path}"
  mkdir -p "${app_path}/Contents/MacOS"
  mkdir -p "${app_path}/Contents/Resources"

  cat > "${app_path}/Contents/MacOS/launch" <<LAUNCH
#!/bin/bash
set -euo pipefail
# --- FBS Account ${n} : isolated Wine prefix (fixes self-close) ---
export WINEPREFIX="${inst_prefix}"
export WINEDEBUG=-all
MT5_APP="\${HOME}/Desktop/MetaTrader 5.app"
WINE_BIN="\${MT5_APP}/Contents/SharedSupport/wine/bin/wine"
WINESERVER_BIN="\${MT5_APP}/Contents/SharedSupport/wine/bin/wineserver"
ACCOUNTS_DIR="\${HOME}/Library/Application Support/mt5-fbs-accounts"
CONF="\${ACCOUNTS_DIR}/account${n}.conf"
INSTANCE_TAG="${term_dir}/terminal64.exe"
ARGS=(/portable)

if [[ ! -x "\${WINE_BIN}" ]]; then
  osascript -e 'display alert "MetaTrader 5.app not on Desktop" message "Keep MetaTrader 5.app on Desktop for Wine."' as critical
  exit 1
fi

# GUARD: if this instance is already running, do NOT kill it -- just notify & exit.
# (Re-launching used to run "wineserver -k", which closed the running terminal = self-close.)
if pgrep -f "\${INSTANCE_TAG}" >/dev/null 2>&1; then
  osascript -e 'display notification "FBS Account ${n} is already running" with title "FBS"' 2>/dev/null || true
  exit 0
fi

# Safe now (nothing running in this prefix): clear any leftover/stale wineserver for THIS prefix only.
if [[ -x "\${WINESERVER_BIN}" ]]; then
  WINEPREFIX="\${WINEPREFIX}" "\${WINESERVER_BIN}" -k 2>/dev/null || true
  sleep 1
fi

if [[ -f "\${CONF}" ]]; then
  # shellcheck disable=SC1090
  source "\${CONF}"
  if [[ -n "\${LOGIN:-}" && -n "\${PASSWORD:-}" && -n "\${SERVER:-}" ]]; then
    ARGS+=(/login:"\${LOGIN}" /password:"\${PASSWORD}" /server:"\${SERVER}")
  fi
fi

exec "\${WINE_BIN}" "${term_path}" "\${ARGS[@]}"
LAUNCH
  chmod +x "${app_path}/Contents/MacOS/launch"

  if [[ -f "${ICON_SRC}" ]]; then
    cp "${ICON_SRC}" "${app_path}/Contents/Resources/AppIcon.icns"
  fi

  cat > "${app_path}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${app_name}</string>
  <key>CFBundleExecutable</key>
  <string>launch</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleName</key>
  <string>${app_name}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.14</string>
</dict>
</plist>
PLIST

  printf 'APPL????' > "${app_path}/Contents/PkgInfo"
  echo "Created: ${app_path}"
}

for n in 1 2 3 4; do
  create_fbs_instance_app "${n}"
done

APP_PATH="${DESKTOP}/FBS.app"
rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cat > "${APP_PATH}/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/bash
set -euo pipefail
DESKTOP="${HOME}/Desktop"

for n in 1 2 3 4; do
  open -n "${DESKTOP}/FBS Account ${n}.app"
  sleep 2
done

osascript -e 'display notification "Opened 4 FBS MT5 windows (accounts 1–4)" with title "FBS"' 2>/dev/null || true
LAUNCH
chmod +x "${APP_PATH}/Contents/MacOS/launch"

if [[ -f "${ICON_SRC}" ]]; then
  cp "${ICON_SRC}" "${APP_PATH}/Contents/Resources/AppIcon.icns"
fi

cat > "${APP_PATH}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>FBS</string>
  <key>CFBundleExecutable</key>
  <string>launch</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>net.metaquotes.wine.FBS.4accounts</string>
  <key>CFBundleName</key>
  <string>FBS</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.14</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "${APP_PATH}/Contents/PkgInfo"
echo "Created: ${APP_PATH}"
echo "Done. Use FBS.app or FBS Account 1–4.app on Desktop."
