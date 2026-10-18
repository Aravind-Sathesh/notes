#!/bin/bash
# Builds Notes.app from Sources/*.swift and the page files. Re-run after editing any.
set -euo pipefail
cd "$(dirname "$0")"

APP="Notes.app"
BUILD=".build"

rm -rf "$APP" "$BUILD"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD/icon.iconset"

# The editor is bundled from tools/cm-entry.js when the toolchain is present;
# otherwise the committed codemirror.js is used as-is.
if [ -x tools/node_modules/.bin/esbuild ]; then
  echo "bundling editor…"
  tools/node_modules/.bin/esbuild tools/cm-entry.js \
      --bundle --format=iife --global-name=NotesEditor \
      --minify --target=safari15 --outfile=codemirror.js >/dev/null
fi

echo "compiling…"
swiftc Sources/*.swift -O -o "$BUILD/Notes" -framework Cocoa -framework WebKit

echo "rendering icon…"
# icon.png is the artwork when it is there; the built-in mark is the fallback,
# so the icon survives a rebuild either way.
"$BUILD/Notes" --write-icon "$BUILD/icon.iconset" ${ICON_SOURCE:-$([ -f icon.png ] && echo icon.png)}
cd "$BUILD/icon.iconset"
for pair in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $pair
  cp "icon_$1.png" "icon_$2.png"
done
rm -f icon_16.png icon_64.png icon_1024.png
cd ../..
iconutil -c icns "$BUILD/icon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

echo "assembling bundle…"
mv "$BUILD/Notes" "$APP/Contents/MacOS/Notes"
cp notes.html bridge.js bridge.css codemirror.js THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
cp -R fonts "$APP/Contents/Resources/fonts"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>          <string>Notes</string>
    <key>CFBundleIdentifier</key>          <string>com.aravind.notes</string>
    <key>CFBundleName</key>                <string>Notes</string>
    <key>CFBundleDisplayName</key>         <string>Notes</string>
    <key>CFBundleIconFile</key>            <string>AppIcon</string>
    <key>CFBundlePackageType</key>         <string>APPL</string>
    <key>CFBundleVersion</key>             <string>1.0</string>
    <key>CFBundleShortVersionString</key>  <string>1.0</string>
    <key>LSMinimumSystemVersion</key>      <string>12.0</string>
    <key>LSApplicationCategoryType</key>   <string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key>     <true/>

    <!-- Explains the prompt macOS shows the first time Cmd+S writes there. -->
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Notes saves your notes as text files in a Notes folder inside Documents.</string>

    <!-- Declared as an editor so Notes appears under Open With and can be made
         the default for text files. Rank is Alternate rather than Owner: this
         app does not own plain text, and should not seize the association for
         every .txt on the system just by being installed. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>   <string>Text Note</string>
            <key>CFBundleTypeRole</key>   <string>Editor</string>
            <key>LSHandlerRank</key>      <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.plain-text</string>
                <string>public.utf8-plain-text</string>
                <string>net.daringfireball.markdown</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc signature: keeps the bundle identity stable so macOS does not treat
# each rebuild as a new app and orphan the saved notes.
codesign --force --sign - "$APP" >/dev/null 2>&1

rm -rf "$BUILD"
echo "built $APP"
