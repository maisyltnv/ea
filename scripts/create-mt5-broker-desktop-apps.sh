#!/bin/bash
# Creates Market4You MT5.app and WeMasterTrade MT5.app on ~/Desktop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DESKTOP="${HOME}/Desktop"
WINE_PREFIX="${HOME}/Library/Application Support/net.metaquotes.wine.metatrader5"
MT5_APP="${DESKTOP}/MetaTrader 5.app"
WINE_BIN="${MT5_APP}/Contents/SharedSupport/wine/bin/wine"
ICON_SRC="${MT5_APP}/Contents/Resources/AppIcon.icns"

if [[ ! -x "${WINE_BIN}" ]]; then
  echo "Error: MetaTrader 5.app not found on Desktop (need bundled Wine)."
  echo "Expected: ${MT5_APP}"
  exit 1
fi

create_app() {
  local name="$1"
  local subdir="$2"
  local bundle_id="$3"
  local app_path="${DESKTOP}/${name}.app"
  local term_path="${WINE_PREFIX}/drive_c/Program Files/${subdir}/terminal64.exe"

  if [[ ! -f "${term_path}" ]]; then
    echo "Error: missing ${term_path}"
    exit 1
  fi

  rm -rf "${app_path}"
  mkdir -p "${app_path}/Contents/MacOS"
  mkdir -p "${app_path}/Contents/Resources"

  cat > "${app_path}/Contents/MacOS/launch" <<LAUNCH
#!/bin/bash
export WINEPREFIX="${WINE_PREFIX}"
export WINEDEBUG=-all
MT5_APP="\${HOME}/Desktop/MetaTrader 5.app"
WINE_BIN="\${MT5_APP}/Contents/SharedSupport/wine/bin/wine"
if [[ ! -x "\${WINE_BIN}" ]]; then
  osascript -e 'display alert "MetaTrader 5.app not on Desktop" message "Keep MetaTrader 5.app on Desktop for Wine."' as critical
  exit 1
fi
exec "\${WINE_BIN}" "${term_path}"
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
  <string>${name}</string>
  <key>CFBundleExecutable</key>
  <string>launch</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>${bundle_id}</string>
  <key>CFBundleName</key>
  <string>${name}</string>
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

create_app "Market4You MT5" "Market4You" "net.metaquotes.wine.Market4You"
create_app "WeMasterTrade MT5" "WeMasterTrade" "net.metaquotes.wine.WeMasterTrade"

"${SCRIPT_DIR}/fix-mt5-window-position.sh" || true
echo "Done. Double-click icons on Desktop to open each terminal."
