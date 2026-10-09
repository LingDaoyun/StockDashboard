#!/bin/zsh
set -euo pipefail

label="cn.local.AShareDesktop.login"
gui_domain="gui/$(id -u)"
launch_plist="$HOME/Library/LaunchAgents/$label.plist"
if /bin/launchctl print "$gui_domain/$label" >/dev/null 2>&1; then
    /bin/launchctl bootout "$gui_domain/$label"
fi
rm -f "$launch_plist"
print "已移除当前用户登录自启动；app、自选股和外观设置均保留。"
