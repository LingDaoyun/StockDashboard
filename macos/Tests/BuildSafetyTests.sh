#!/bin/zsh
set -euo pipefail

build_script="${0:A:h:h}/build.sh"
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
    case_dir="$test_dir/$1"
    app_dir="$case_dir/A股桌面行情.app"
    mkdir -p "$case_dir/macos/Assets" "$case_dir/bin"
    cp "$build_script" "$case_dir/macos/build.sh"
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
    chmod +x "$case_dir/bin/xcrun" "$case_dir/bin/codesign"
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
    env PATH="$case_dir/bin:$PATH" BUILD_SAFETY_FAIL_MODE="${1:-}" \
        /bin/zsh "$case_dir/macos/build.sh" > "$case_dir/build.log" 2>&1
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
backups=("$case_dir"/.AShareDesktop-build-backup.*(N))
check "old matching app has one backup" test "${#backups}" = 1
if (( ${#backups} == 1 )); then
    check "backup retains old nested symlink" test -L "${backups[1]}/A股桌面行情.app/Contents/MacOS"
    check "backup retains old Info.plist" cmp -s "$case_dir/original/Info.plist" "${backups[1]}/A股桌面行情.app/Contents/Info.plist"
fi
check "successful replacement cleans staging" no_staging

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

if (( failures > 0 )); then
    print -u2 "FAIL: $failures of $checks build safety assertions"
    exit 1
fi
print "PASS: $checks build safety assertions"
