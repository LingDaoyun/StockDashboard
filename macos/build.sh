#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
output_dir="${project_dir:h}"
app_dir="$output_dir/A股桌面行情.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  "$project_dir/Sources/Quotes.swift" \
  "$project_dir/Sources/Tracking.swift" \
  "$project_dir/Sources/TrackingViews.swift" \
  "$project_dir/Sources/EdgeGeometry.swift" \
  "$project_dir/Sources/EdgeDocking.swift" \
  "$project_dir/Sources/WindowDragging.swift" \
  "$project_dir/Sources/DesktopApp.swift" \
  "$project_dir/Sources/main.swift" \
  -o "$app_dir/Contents/MacOS/AShareDesktop"

cp "$project_dir/Assets/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"

cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AShareDesktop</string>
  <key>CFBundleIdentifier</key><string>cn.local.AShareDesktop</string>
  <key>CFBundleName</key><string>A股桌面行情</string>
  <key>CFBundleDisplayName</key><string>A股桌面行情</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.7.4</string>
  <key>CFBundleVersion</key><string>14</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
</dict></plist>
PLIST

codesign --force --sign - "$app_dir"
print "已生成：$app_dir"
