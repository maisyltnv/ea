#!/bin/bash
# Creates ~/Desktop/FBS.app — launches 4 FBS MT5 instances (different accounts).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP="${HOME}/Desktop"
WINE_PREFIX="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5"
MT5_APP="${DESKTOP}/MetaTrader 5.app"
ICON_SRC="${MT5_APP}/Contents/Resources/AppIcon.icns"
APP_PATH="${DESKTOP}/FBS.app"
ACCOUNTS_DIR="${HOME}/Library/Application Support/mt5-fbs-accounts"

if [[ ! -x "${MT5_APP}/Contents/SharedSupport/wine/bin/wine" ]]; then
  echo "Error: MetaTrader 5.app must be on Desktop."
  exit 1
fi

"${SCRIPT_DIR}/setup-fbs-4-mt5-instances.sh"

rm -rf "${APP_PATH}"
mkdir -p "${APP_PATH}/Contents/MacOS"
mkdir -p "${APP_PATH}/Contents/Resources"

cat > "${APP_PATH}/Contents/MacOS/launch" <<'LAUNCH'
#!/bin/bash
set -euo pipefail

export WINEDEBUG=-all
WINE_PREFIX="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5"
ACCOUNTS_DIR="${HOME}/Library/Application Support/mt5-fbs-accounts"
MT5_APP="${HOME}/Desktop/MetaTrader 5.app"
WINE_BIN="${MT5_APP}/Contents/SharedSupport/wine/bin/wine"
PF="${WINE_PREFIX}/drive_c/Program Files"

if [[ ! -x "${WINE_BIN}" ]]; then
  osascript -e 'display alert "FBS" message "Put MetaTrader 5.app on Desktop first."' as critical
  exit 1
fi

export WINEPREFIX="${WINE_PREFIX}"

launch_one() {
  local n="$1"
  local dir="${PF}/MetaTrader 5-FBS-${n}"
  local conf="${ACCOUNTS_DIR}/account${n}.conf"
  local args=(/portable)

  if [[ -f "${conf}" ]]; then
    # shellcheck disable=SC1090
    source "${conf}"
    if [[ -n "${LOGIN:-}" && -n "${PASSWORD:-}" && -n "${SERVER:-}" ]]; then
      args+=(/login:"${LOGIN}" /password:"${PASSWORD}" /server:"${SERVER}")
    fi
  fi

  if [[ ! -f "${dir}/terminal64.exe" ]]; then
    osascript -e "display alert \"FBS\" message \"Missing MetaTrader 5-FBS-${n}. Run setup-fbs-4-mt5-instances.sh\"" as critical
    return 1
  fi

  "${WINE_BIN}" "${dir}/terminal64.exe" "${args[@]}" &
}

for n in 1 2 3 4; do
  launch_one "${n}"
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
