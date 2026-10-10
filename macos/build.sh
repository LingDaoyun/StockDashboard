#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
output_dir="${project_dir:h}"
app_dir="$output_dir/A股桌面行情.app"
bundle_id="cn.local.AShareDesktop"

check_output_path() {
    if [[ -L "$app_dir" ]] || { [[ -e "$app_dir" ]] && \
       { [[ ! -d "$app_dir" ]] || \
         [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app_dir/Contents/Info.plist" 2>/dev/null)" != "$bundle_id" ]]; }; }; then
        print -u2 "同名输出路径不是本程序，拒绝覆盖：$app_dir"
        exit 1
    fi
}

check_output_path
staging_dir="$(mktemp -d "$output_dir/.AShareDesktop-build.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
staging_app="$staging_dir/A股桌面行情.app"
mkdir -p "$staging_app/Contents/MacOS" "$staging_app/Contents/Resources"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx13.0 \
  "$project_dir/Sources/Quotes.swift" \
  "$project_dir/Sources/Tracking.swift" \
  "$project_dir/Sources/Fees.swift" \
  "$project_dir/Sources/TrackingViews.swift" \
  "$project_dir/Sources/EdgeGeometry.swift" \
  "$project_dir/Sources/EdgeDocking.swift" \
  "$project_dir/Sources/WindowDragging.swift" \
  "$project_dir/Sources/DesktopApp.swift" \
  "$project_dir/Sources/main.swift" \
  -o "$staging_app/Contents/MacOS/AShareDesktop"

cp "$project_dir/Assets/AppIcon.icns" "$staging_app/Contents/Resources/AppIcon.icns"

cat > "$staging_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>AShareDesktop</string>
  <key>CFBundleIdentifier</key><string>cn.local.AShareDesktop</string>
  <key>CFBundleName</key><string>A股桌面行情</string>
  <key>CFBundleDisplayName</key><string>A股桌面行情</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.7.7</string>
  <key>CFBundleVersion</key><string>17</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.finance</string>
</dict></plist>
PLIST

codesign --force --sign - "$staging_app"

# Recheck after compilation, then move the old bundle without following its internal links.
check_output_path
backup_dir=""
if [[ -e "$app_dir" ]]; then
    backup_dir="$(mktemp -d "$output_dir/.AShareDesktop-build-backup.XXXXXX")"
    mv "$app_dir" "$backup_dir/A股桌面行情.app"
fi
if ! mv "$staging_app" "$app_dir"; then
    if [[ -n "$backup_dir" ]]; then
        mv "$backup_dir/A股桌面行情.app" "$app_dir"
    fi
    exit 1
fi
if [[ -n "$backup_dir" ]]; then
    print "旧构建备份：$backup_dir/A股桌面行情.app"
fi
print "已生成：$app_dir"
