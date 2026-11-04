#!/bin/bash
# Builds build/MemLens.app.
#   ./build.sh             build only
#   ./build.sh --install   build, install to ~/Applications/MemLens.app and launch it from there
# Optional: SIGN_ID="<codesigning identity>" ./build.sh
set -euo pipefail
cd "$(dirname "$0")"

INSTALL=false
[ "${1:-}" = "--install" ] && INSTALL=true

swift build -c release
BIN="$(swift build -c release --show-bin-path)/MemLens"

APP=build/MemLens.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MemLens"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# A stable identity keeps the Automation/Accessibility grants across rebuilds; ad-hoc signing resets them.
if [ -z "${SIGN_ID:-}" ]; then
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  # First identity; awk reads all input (no early exit) so pipefail can't trip on SIGPIPE.
  SIGN_ID="$(printf '%s\n' "$IDENTITIES" | awk -F'"' 'NF>2 && !found {print $2; found=1}')"
fi
if [ -n "$SIGN_ID" ]; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "Signed with: $SIGN_ID"
else
  if $INSTALL; then
    echo "error: no code signing identity found; refusing to install an ad-hoc build (permissions would reset)" >&2
    exit 1
  fi
  codesign --force --sign - "$APP"
  echo "warning: ad-hoc signed; permissions will be asked again after every rebuild"
fi

if ! $INSTALL; then
  echo "Built $APP — run it with: open $APP   (or ./build.sh --install)"
  exit 0
fi

DEST="$HOME/Applications/MemLens.app"
pkill -x MemLens || true
for _ in $(seq 1 25); do pgrep -x MemLens >/dev/null || break; sleep 0.2; done
pkill -9 -x MemLens || true

# Fresh copy (new inode) so the kernel doesn't reuse the old cached code signature.
mkdir -p "$HOME/Applications"
rm -rf "$DEST"
ditto "$APP" "$DEST"

# Forget the build copy so LaunchServices only knows the installed one.
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
[ -x "$LSREGISTER" ] && "$LSREGISTER" -u "$PWD/$APP" >/dev/null 2>&1 || true

open "$DEST"
echo "Installed and launched $DEST"
