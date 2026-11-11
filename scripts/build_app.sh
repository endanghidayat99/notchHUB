#!/bin/zsh
# Builds NotchHub.app (release) into ./build and ad-hoc signs it.
#   ./scripts/build_app.sh            → build/NotchHub.app
#   ./scripts/build_app.sh --install  → also copies to /Applications
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64 --arch x86_64 2>/dev/null || swift build -c release
BIN=$(swift build -c release --show-bin-path)

APP=build/NotchHub.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/NotchHub" "$APP/Contents/MacOS/NotchHub"
# Embed dynamic frameworks from SwiftPM binary targets (e.g. Lottie.xcframework)
find "$BIN" -maxdepth 3 -name "*.framework" -type d -prune | while read -r fw; do
  rm -rf "$APP/Contents/Frameworks/$(basename "$fw")"
  cp -R "$fw" "$APP/Contents/Frameworks/"
  echo "  embedded $(basename "$fw")"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/NotchHub" 2>/dev/null || true
cp scripts/Info.plist "$APP/Contents/Info.plist"
# SwiftPM resource bundles of dependencies (e.g. Lottie), if any
for b in "$BIN"/*.bundle(N); do cp -R "$b" "$APP/Contents/Resources/"; done

for fw in "$APP"/Contents/Frameworks/*.framework(N); do codesign --force --sign - "$fw"; done
codesign --force --sign - --entitlements scripts/NotchHub.entitlements "$APP"
echo "✅ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  rm -rf /Applications/NotchHub.app
  cp -R "$APP" /Applications/
  echo "✅ Installed to /Applications/NotchHub.app"
fi
