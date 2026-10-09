#!/bin/zsh
set -eu
cd "${0:A:h}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ashare-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 Sources/Quotes.swift Tests/QuoteTests.swift -o "$test_dir/quote-tests"
"$test_dir/quote-tests" "$@"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/Quotes.swift Sources/DesktopApp.swift Tests/WatchlistTests.swift -o "$test_dir/watchlist-tests"
"$test_dir/watchlist-tests"
