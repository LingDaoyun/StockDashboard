import AppKit
import SwiftUI
import Combine

@MainActor
final class ExpandedChartWindow: NSWindowController {
    private let store: QuoteStore
    private var selection: AnyCancellable?

    init(store: QuoteStore, annotationStore: DailyChartAnnotationStore = DailyChartAnnotationStore()) {
        self.store = store
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 540),
                            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.contentMinSize = NSSize(width: 560, height: 360)
        panel.contentView = NSHostingView(rootView: ExpandedChartView(store: store, annotationStore: annotationStore))
        super.init(window: panel)
        selection = store.$expandedChartSymbolID.combineLatest(store.$chartKind).sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateSelection() }
        }
    }

    required init?(coder: NSCoder) { nil }

    func show(on screen: NSScreen?) {
        guard store.expandedChartSymbolID != nil, let window,
              let screen = screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        window.setContentSize(NSSize(width: min(900, visible.width - 48),
                                     height: min(540, visible.height - 80)))
        window.setFrameOrigin(NSPoint(x: visible.midX - window.frame.width / 2,
                                      y: visible.midY - window.frame.height / 2))
        updateSelection()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func updateSelection() {
        guard let id = store.expandedChartSymbolID else {
            close()
            return
        }
        let name = DashboardIndex.all.first { $0.id == id }?.title ?? store.quotes[id]?.name ?? id.uppercased()
        window?.title = "\(name) · \(id.uppercased()) · \(store.chartKind.title)"
    }
}

private struct ExpandedChartView: View {
    @ObservedObject var store: QuoteStore
    let annotationStore: DailyChartAnnotationStore

    var body: some View {
        GeometryReader { geometry in
            Group {
                if store.chartKind == .dailyKLine {
                    DailyKLineChartView(snapshot: store.dailyKLineSnapshot, error: store.dailyKLineError,
                                       isRefreshing: store.isDailyKLineRefreshing,
                                       chartHeight: max(220, geometry.size.height - 32),
                                       interactive: true, annotationStore: annotationStore)
                } else {
                    IntradayChartView(snapshot: store.intradaySnapshot, error: store.intradayError,
                                      isRefreshing: store.isIntradayRefreshing, now: store.marketNow,
                                      isOpeningAuction: store.selectedList == .holdings
                                        && OpeningAuctionHistory.isActive(at: store.marketNow),
                                      chartHeight: max(220, geometry.size.height - 32))
                }
            }
            .id((store.expandedChartSymbolID ?? "") + store.chartKind.title)
            .padding(16)
        }
    }
}
