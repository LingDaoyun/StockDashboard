#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h}"
source_app="${project_dir:h}/A股桌面行情.app"
apps_dir="$HOME/Applications"
installed_app="$apps_dir/A股桌面行情.app"
bundle_id="cn.local.AShareDesktop"
label="$bundle_id.login"
launch_dir="$HOME/Library/LaunchAgents"
launch_plist="$launch_dir/$label.plist"
gui_domain="gui/$(id -u)"

if [[ ! -x "$source_app/Contents/MacOS/AShareDesktop" ]] || \
   [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$source_app/Contents/Info.plist" 2>/dev/null)" != "$bundle_id" ]]; then
    print -u2 "未找到正确的已构建 app，请先运行 ./build.sh。"
    exit 1
fi
if [[ -L "$installed_app" ]] || { [[ -e "$installed_app" ]] && \
   [[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$installed_app/Contents/Info.plist" 2>/dev/null)" != "$bundle_id" ]]; }; then
    print -u2 "同名路径不是本程序，拒绝覆盖：$installed_app"
    exit 1
fi

# 内容相同可重复启用；更新前要求正常退出，避免运行旧版本。
if [[ ! -d "$installed_app" ]] || ! /usr/bin/diff -qr "$source_app" "$installed_app" >/dev/null; then
    if /usr/bin/pgrep -x AShareDesktop >/dev/null; then
        print -u2 "请先从 A股桌面行情 菜单选择退出，再运行本脚本。"
        exit 1
    fi
    mkdir -p "$apps_dir"
    staging_dir="$(mktemp -d "$apps_dir/.AShareDesktop-install.XXXXXX")"
    trap 'rm -rf "$staging_dir"' EXIT
    /usr/bin/ditto "$source_app" "$staging_dir/A股桌面行情.app"
    if [[ -e "$installed_app" ]]; then
        backup_dir="$(mktemp -d "$apps_dir/.AShareDesktop-backup.XXXXXX")"
        mv "$installed_app" "$backup_dir/A股桌面行情.app"
        print "旧版本备份：$backup_dir/A股桌面行情.app"
    fi
    mv "$staging_dir/A股桌面行情.app" "$installed_app"
fi

mkdir -p "$launch_dir"
temporary_plist="$(mktemp "$launch_dir/.AShareDesktop-login.XXXXXX")"
/usr/bin/plutil -create xml1 "$temporary_plist"
/usr/bin/plutil -insert Label -string "$label" "$temporary_plist"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$temporary_plist"
/usr/bin/plutil -insert ProgramArguments.0 -string /usr/bin/open "$temporary_plist"
/usr/bin/plutil -insert ProgramArguments.1 -string -g "$temporary_plist"
/usr/bin/plutil -insert ProgramArguments.2 -string -a "$temporary_plist"
/usr/bin/plutil -insert ProgramArguments.3 -string "$installed_app" "$temporary_plist"
/usr/bin/plutil -insert RunAtLoad -bool true "$temporary_plist"
/usr/bin/plutil -lint "$temporary_plist"
chmod 644 "$temporary_plist"
if /bin/launchctl print "$gui_domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$gui_domain/$label"
fi
mv "$temporary_plist" "$launch_plist"
/bin/launchctl enable "$gui_domain/$label"
/bin/launchctl bootstrap "$gui_domain" "$launch_plist"
print "已安装并启用当前用户登录自启动：$installed_app"
print "启动项：$launch_plist"
print "未执行整机重启；登录启动通过当前用户 LaunchAgent 配置。"
