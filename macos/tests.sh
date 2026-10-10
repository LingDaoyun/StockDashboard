#!/bin/zsh
set -eu
cd "${0:A:h}"
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/ashare-tests.XXXXXX")"
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -swift-version 6 Sources/Quotes.swift Tests/QuoteTests.swift -o "$test_dir/quote-tests"
"$test_dir/quote-tests" "$@"
xcrun swiftc -swift-version 6 Sources/Quotes.swift Sources/Tracking.swift Tests/TrackingTests.swift -o "$test_dir/tracking-tests"
"$test_dir/tracking-tests"
xcrun swiftc -swift-version 6 Sources/Quotes.swift Sources/Tracking.swift Sources/Fees.swift Tests/FeeTests.swift -o "$test_dir/fee-tests"
"$test_dir/fee-tests"
xcrun swiftc -swift-version 6 Sources/EdgeGeometry.swift Tests/EdgeGeometryTests.swift -o "$test_dir/edge-geometry-tests"
"$test_dir/edge-geometry-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/EdgeGeometry.swift Sources/EdgeDocking.swift Tests/EdgeDockingTests.swift -o "$test_dir/edge-docking-tests"
"$test_dir/edge-docking-tests"
xcrun swiftc -swift-version 5 -target arm64-apple-macosx13.0 Sources/Quotes.swift Sources/Tracking.swift Sources/Fees.swift Sources/TrackingViews.swift Sources/EdgeGeometry.swift Sources/EdgeDocking.swift Sources/WindowDragging.swift Sources/DesktopApp.swift Tests/WatchlistTests.swift -o "$test_dir/watchlist-tests"
"$test_dir/watchlist-tests"
