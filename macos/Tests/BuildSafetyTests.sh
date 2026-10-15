#!/bin/zsh
set -euo pipefail

build_script="${0:A:h:h}/build.sh"
install_script="${0:A:h:h}/install-login.sh"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ashare-build-safety.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
checks=0
failures=0

check() {
    local message="$1"
    shift
    ((checks += 1))
    if ! "$@"; then
        print -u2 "FAIL: $message"
        ((failures += 1))
    fi
}

make_case() {
    case_dir="${test_dir:A}/$1"
    app_dir="$case_dir/A股桌面行情.app"
    mkdir -p "$case_dir/macos/Assets" "$case_dir/bin"
    cp "$build_script" "$case_dir/macos/build.sh"
    /usr/bin/sed -e "s|/usr/bin/pgrep|$case_dir/bin/pgrep|g" \
        -e "s|/bin/launchctl|$case_dir/bin/launchctl|g" \
        -e "s|^apps_dir=.*|apps_dir=\"$case_dir/home/Applications\"|" \
        -e "s|^launch_dir=.*|launch_dir=\"$case_dir/home/Library/LaunchAgents\"|" \
        "$install_script" > "$case_dir/macos/install-login.sh"
    print -r -- synthetic-icon > "$case_dir/macos/Assets/AppIcon.icns"
    cat > "$case_dir/bin/xcrun" <<'SH'
#!/bin/zsh
set -euo pipefail
print -r -- synthetic-new-binary > "${argv[-1]}"
if [[ "${BUILD_SAFETY_FAIL_MODE:-}" == compile ]]; then exit 42; fi
SH
    cat > "$case_dir/bin/codesign" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "${BUILD_SAFETY_FAIL_MODE:-}" == sign ]]; then exit 43; fi
/usr/bin/plutil -lint "${argv[-1]}/Contents/Info.plist" >/dev/null
SH
    cat > "$case_dir/bin/ditto" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "${BUILD_SAFETY_FAIL_MODE:-}" == archive && "$1" == -c ]]; then
    print -r -- incomplete-archive > "${argv[-1]}"
    exit 44
fi
exec /usr/bin/ditto "$@"
SH
    cat > "$case_dir/bin/mv" <<'SH'
#!/bin/zsh
set -euo pipefail
if [[ "${BUILD_SAFETY_FAIL_MODE:-}" == replace* && "$2" == "$BUILD_SAFETY_APP_PATH" ]]; then
    if [[ "$1" == */.AShareDesktop-build.*/A股桌面行情.app || \
          "$1" == */.AShareDesktop-install.*/A股桌面行情.app || \
          "${BUILD_SAFETY_FAIL_MODE:-}" == replace-rollback ]]; then
        exit 45
    fi
fi
exec /bin/mv "$@"
SH
    cat > "$case_dir/bin/pgrep" <<'SH'
#!/bin/zsh
exit 1
SH
    cat > "$case_dir/bin/launchctl" <<'SH'
#!/bin/zsh
if [[ "$1" == print ]]; then exit 1; fi
exit 0
SH
    chmod +x "$case_dir/bin/"*
}

make_old_app() {
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources" "$case_dir/original"
    print -r -- synthetic-old-binary > "$app_dir/Contents/MacOS/AShareDesktop"
    print -r -- synthetic-old-icon > "$app_dir/Contents/Resources/AppIcon.icns"
    /usr/bin/plutil -create xml1 "$app_dir/Contents/Info.plist"
    /usr/bin/plutil -insert CFBundleIdentifier -string "$1" "$app_dir/Contents/Info.plist"
    cp "$app_dir/Contents/Info.plist" "$case_dir/original/Info.plist"
    cp "$app_dir/Contents/MacOS/AShareDesktop" "$case_dir/original/AShareDesktop"
    cp "$app_dir/Contents/Resources/AppIcon.icns" "$case_dir/original/AppIcon.icns"
}

run_build() {
    env PATH="$case_dir/bin:$PATH" BUILD_SAFETY_FAIL_MODE="${1:-}" BUILD_SAFETY_APP_PATH="$app_dir" \
        /bin/zsh "$case_dir/macos/build.sh" > "$case_dir/build.log" 2>&1
}

run_install() {
    env PATH="$case_dir/bin:$PATH" \
        BUILD_SAFETY_FAIL_MODE="${1:-}" BUILD_SAFETY_APP_PATH="$installed_app" \
        /bin/zsh "$case_dir/macos/install-login.sh" > "$case_dir/install.log" 2>&1
}

no_staging() {
    local entries=("$case_dir"/.AShareDesktop-build.*(N))
    (( ${#entries} == 0 ))
}

make_case root-symlink
make_old_app cn.local.AShareDesktop
mv "$app_dir" "$case_dir/unrelated-app"
ln -s "$case_dir/unrelated-app" "$app_dir"
if run_build; then build_rejected=false; else build_rejected=true; fi
check "output app symlink must be rejected" test "$build_rejected" = true
check "output symlink target Info.plist remains unchanged" cmp -s "$case_dir/original/Info.plist" "$case_dir/unrelated-app/Contents/Info.plist"
check "output symlink target executable remains unchanged" cmp -s "$case_dir/original/AShareDesktop" "$case_dir/unrelated-app/Contents/MacOS/AShareDesktop"
check "rejected output symlink remains a symlink" test -L "$app_dir"
check "rejected build leaves no staging" no_staging

make_case foreign-app
make_old_app synthetic.unrelated.app
if run_build; then build_rejected=false; else build_rejected=true; fi
check "same-name unrelated app must be rejected" test "$build_rejected" = true
check "unrelated app Info.plist remains unchanged" cmp -s "$case_dir/original/Info.plist" "$app_dir/Contents/Info.plist"
check "unrelated app executable remains unchanged" cmp -s "$case_dir/original/AShareDesktop" "$app_dir/Contents/MacOS/AShareDesktop"
check "rejected unrelated app leaves no staging" no_staging

make_case nested-symlink
make_old_app cn.local.AShareDesktop
mv "$app_dir/Contents/MacOS" "$case_dir/unrelated-files"
ln -s "$case_dir/unrelated-files" "$app_dir/Contents/MacOS"
if run_build; then build_succeeded=true; else build_succeeded=false; fi
check "matching app with nested symlink may be replaced" test "$build_succeeded" = true
check "nested symlink target executable remains unchanged" cmp -s "$case_dir/original/AShareDesktop" "$case_dir/unrelated-files/AShareDesktop"
check "replacement app has a real MacOS directory" test ! -L "$app_dir/Contents/MacOS"
archives=("$case_dir"/.AShareDesktop-build-backup.*.zip(N))
backups=("$case_dir"/.AShareDesktop-build-backup.*(N/))
check "old matching app has one compressed backup" test "${#archives}" = 1
check "successful build leaves no loose backup app" test "${#backups}" = 0
if (( ${#archives} == 1 )); then
    check "build backup archive can be restored" /usr/bin/ditto -x -k "${archives[1]}" "$case_dir/restored"
    check "archive retains old nested symlink" test -L "$case_dir/restored/A股桌面行情.app/Contents/MacOS"
    check "archive retains old Info.plist" cmp -s "$case_dir/original/Info.plist" "$case_dir/restored/A股桌面行情.app/Contents/Info.plist"
fi
check "successful replacement cleans staging" no_staging

make_case archive-failure
make_old_app cn.local.AShareDesktop
if run_build archive; then build_succeeded=true; else build_succeeded=false; fi
check "archive failure does not reject successful build" test "$build_succeeded" = true
check "archive failure keeps the new build" /usr/bin/grep -q synthetic-new-binary "$app_dir/Contents/MacOS/AShareDesktop"
backups=("$case_dir"/.AShareDesktop-build-backup.*(N/))
check "archive failure retains one loose old app" test "${#backups}" = 1
if (( ${#backups} == 1 )); then
    check "archive failure preserves old executable" cmp -s "$case_dir/original/AShareDesktop" "${backups[1]}/A股桌面行情.app/Contents/MacOS/AShareDesktop"
fi
check "archive failure is reported" /usr/bin/grep -q '归档失败' "$case_dir/build.log"
archives=("$case_dir"/.AShareDesktop-build-backup.*.zip(N))
check "archive failure removes incomplete build zip" test "${#archives}" = 0

for fail_mode in replace replace-rollback; do
    make_case "failed-$fail_mode"
    make_old_app cn.local.AShareDesktop
    if run_build "$fail_mode"; then build_rejected=false; else build_rejected=true; fi
    check "$fail_mode failure exits unsuccessfully" test "$build_rejected" = true
    archives=("$case_dir"/.AShareDesktop-build-backup.*.zip(N))
    check "$fail_mode failure does not archive the old app" test "${#archives}" = 0
    if [[ "$fail_mode" == replace ]]; then
        check "replacement failure restores old executable" cmp -s "$case_dir/original/AShareDesktop" "$app_dir/Contents/MacOS/AShareDesktop"
    else
        backups=("$case_dir"/.AShareDesktop-build-backup.*(N/))
        check "rollback failure preserves one old app backup" test "${#backups}" = 1
        if (( ${#backups} == 1 )); then
            check "rollback failure preserves old executable" cmp -s "$case_dir/original/AShareDesktop" "${backups[1]}/A股桌面行情.app/Contents/MacOS/AShareDesktop"
        fi
    fi
done

for fail_mode in compile sign; do
    make_case "failed-$fail_mode"
    make_old_app cn.local.AShareDesktop
    if run_build "$fail_mode"; then build_rejected=false; else build_rejected=true; fi
    check "$fail_mode failure exits unsuccessfully" test "$build_rejected" = true
    check "$fail_mode failure retains old Info.plist" cmp -s "$case_dir/original/Info.plist" "$app_dir/Contents/Info.plist"
    check "$fail_mode failure retains old executable" cmp -s "$case_dir/original/AShareDesktop" "$app_dir/Contents/MacOS/AShareDesktop"
    check "$fail_mode failure retains old icon" cmp -s "$case_dir/original/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
    check "$fail_mode failure cleans staging" no_staging
    backups=("$case_dir"/.AShareDesktop-build-backup.*(N))
    check "$fail_mode failure does not move original app" test "${#backups}" = 0
done

make_case 'new app with spaces'
if run_build; then build_succeeded=true; else build_succeeded=false; fi
check "fresh build succeeds in paths containing spaces" test "$build_succeeded" = true
check "fresh build produces expected bundle" test "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app_dir/Contents/Info.plist")" = cn.local.AShareDesktop
check "fresh build cleans staging" no_staging

for fail_mode in success archive replace replace-rollback; do
    make_case "install-$fail_mode"
    make_old_app cn.local.AShareDesktop
    installed_app="$case_dir/home/Applications/A股桌面行情.app"
    mkdir -p "${installed_app:h}"
    cp -R "$app_dir" "$installed_app"
    print -r -- synthetic-new-binary > "$app_dir/Contents/MacOS/AShareDesktop"
    chmod +x "$app_dir/Contents/MacOS/AShareDesktop"
    if run_install "$fail_mode"; then install_succeeded=true; else install_succeeded=false; fi
    archives=("${installed_app:h}"/.AShareDesktop-backup.*.zip(N))
    backups=("${installed_app:h}"/.AShareDesktop-backup.*(N/))
    if [[ "$fail_mode" == success ]]; then
        check "successful install exits successfully" test "$install_succeeded" = true
        check "successful install keeps the new executable" /usr/bin/grep -q synthetic-new-binary "$installed_app/Contents/MacOS/AShareDesktop"
        check "successful install has one compressed old app" test "${#archives}" = 1
        check "successful install leaves no loose old app" test "${#backups}" = 0
        if (( ${#archives} == 1 )); then
            check "installed app archive can be restored" /usr/bin/ditto -x -k "${archives[1]}" "$case_dir/restored"
            check "installed app archive retains old executable" cmp -s "$case_dir/original/AShareDesktop" "$case_dir/restored/A股桌面行情.app/Contents/MacOS/AShareDesktop"
        fi
    elif [[ "$fail_mode" == archive ]]; then
        check "archive failure does not reject successful install" test "$install_succeeded" = true
        check "install archive failure keeps the new executable" /usr/bin/grep -q synthetic-new-binary "$installed_app/Contents/MacOS/AShareDesktop"
        check "install archive failure preserves one loose old app" test "${#backups}" = 1
        if (( ${#backups} == 1 )); then
            check "install archive failure retains old executable" cmp -s "$case_dir/original/AShareDesktop" "${backups[1]}/A股桌面行情.app/Contents/MacOS/AShareDesktop"
        fi
        check "install archive failure is reported" /usr/bin/grep -q '归档失败' "$case_dir/install.log"
        check "archive failure removes incomplete install zip" test "${#archives}" = 0
    else
        check "install $fail_mode exits unsuccessfully" test "$install_succeeded" = false
        check "install $fail_mode does not archive the old app" test "${#archives}" = 0
        if [[ "$fail_mode" == replace ]]; then
            check "install replacement failure restores old executable" cmp -s "$case_dir/original/AShareDesktop" "$installed_app/Contents/MacOS/AShareDesktop"
        else
            check "install rollback failure preserves one old app" test "${#backups}" = 1
            if (( ${#backups} == 1 )); then
                check "install rollback failure retains old executable" cmp -s "$case_dir/original/AShareDesktop" "${backups[1]}/A股桌面行情.app/Contents/MacOS/AShareDesktop"
            fi
        fi
    fi
done

if (( failures > 0 )); then
    print -u2 "FAIL: $failures of $checks build safety assertions"
    exit 1
fi
print "PASS: $checks build safety assertions"
