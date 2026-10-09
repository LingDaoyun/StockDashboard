import AppKit
import SwiftUI
import Combine

private let quoteRowHeight: CGFloat = 78

@MainActor
final class QuoteStore: ObservableObject {
    @Published private(set) var symbols: [StockSymbol]
    @Published private(set) var quotes: [String: Quote] = [:]
    @Published private(set) var unavailable: Set<String> = []
    @Published private(set) var lastReceipt: Date?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published var isAddingStock = false
    @Published var isAdjustingTransparency = false
    @Published var backgroundTransparency: Double {
        didSet { defaults.set(backgroundTransparency, forKey: "backgroundTransparency") }
    }
    @Published var isPinned: Bool {
        didSet { defaults.set(isPinned, forKey: "pinned") }
    }

    let defaults: UserDefaults
    let isPreview: Bool
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var activity: NSObjectProtocol?
    private var suspended = false
    private let client = QuoteClient()

    init(defaults: UserDefaults, preview: String?) {
        self.defaults = defaults
        self.isPreview = preview != nil
        let saved = preview ?? defaults.string(forKey: "symbols") ?? ""
        self.symbols = (try? StockSymbol.parseList(saved)) ?? []
        self.isPinned = defaults.object(forKey: "pinned") as? Bool ?? false
        self.backgroundTransparency = min(1, max(0, defaults.object(forKey: "backgroundTransparency") as? Double ?? 0.3))
    }

    var codeText: String { symbols.map(\.id).joined(separator: ", ") }

    func start() {
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 0.1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateActivity()
        refresh()
    }

    func saveSymbols(_ text: String) throws {
        let values = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? [] : try StockSymbol.parseList(text)
        applySymbols(values)
    }

    func addSymbols(_ text: String) throws {
        let added = try StockSymbol.parseList(text)
        let merged = try StockSymbol.parseList((symbols + added).map(\.id).joined(separator: ","))
        applySymbols(merged)
    }

    func removeSymbol(_ symbol: StockSymbol) {
        applySymbols(symbols.filter { $0 != symbol })
    }

    private func applySymbols(_ values: [StockSymbol]) {
        request?.cancel()
        request = nil
        isRefreshing = false
        symbols = values
        defaults.set(codeText, forKey: "symbols")
        let ids = Set(values.map(\.id))
        quotes = quotes.filter { ids.contains($0.key) }
        unavailable = []
        lastReceipt = nil
        errorMessage = nil
        if values.isEmpty {
            quotes = [:]
        }
        updateActivity()
        refresh()
    }

    func suspend() {
        suspended = true
        request?.cancel()
        request = nil
        isRefreshing = false
        updateActivity()
    }

    func resume() {
        suspended = false
        updateActivity()
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        suspend()
    }

    private func updateActivity() {
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        if !symbols.isEmpty && !suspended {
            activity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "用户指定的桌面行情每3秒刷新"
            )
        }
    }

    func refresh() {
        guard !suspended, !symbols.isEmpty, !isRefreshing else { return }
        let requested = symbols
        isRefreshing = true
        if isPreview {
            print("request \(Date().timeIntervalSince1970) \(requested.map(\.id).joined(separator: ","))")
            fflush(stdout)
        }
        request = Task { [weak self] in
            guard let self else { return }
            do {
                let incoming = try await client.fetch(requested)
                guard !Task.isCancelled else { return }
                let current = Set(symbols.map(\.id))
                let requestedIDs = Set(requested.map(\.id)).intersection(current)
                for (id, quote) in incoming where current.contains(id) {
                    quotes[id] = quote
                }
                unavailable.subtract(requestedIDs)
                unavailable.formUnion(requestedIDs.subtracting(incoming.keys))
                lastReceipt = Date()
                errorMessage = nil
                if isPreview {
                    let values = requested.compactMap { symbol -> String? in
                        guard let q = incoming[symbol.id] else { return nil }
                        return "\(symbol.id)=\(q.name),price:\(q.price),volumeLots:\(q.volumeLots),amountYuan:\(q.amountYuan),quote:\(q.timestamp.timeIntervalSince1970)"
                    }
                    print("received \(Date().timeIntervalSince1970) \(values.joined(separator: " | "))")
                    fflush(stdout)
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                if isPreview {
                    print("failure \(Date().timeIntervalSince1970) \(error.localizedDescription)")
                    fflush(stdout)
                }
            }
            isRefreshing = false
            request = nil
        }
    }
}

enum DisplayFormat {
    static let chinaTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static let receiptTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    static func magnitude(_ value: Double, unit: String) -> String {
        if value >= 100_000_000 { return String(format: "%.2f亿%@", value / 100_000_000, unit) }
        if value >= 10_000 { return String(format: "%.2f万%@", value / 10_000, unit) }
        return String(format: "%.0f%@", value, unit)
    }
}

struct QuoteRow: View {
    let symbol: StockSymbol
    let quote: Quote?
    let failed: Bool
    let unavailable: Bool
    let remove: () -> Void

    private var movement: Color {
        guard let quote else { return .secondary }
        return quote.change > 0 ? Color(red: 0.85, green: 0.19, blue: 0.24)
            : quote.change < 0 ? Color(red: 0.06, green: 0.59, blue: 0.38) : .primary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 5) {
                    Text(quote?.name ?? symbol.code)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if failed || unavailable {
                        Text(quote == nil ? "无行情" : "上次数据")
                            .font(.system(size: 9)).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(quote.map { String(format: "%.2f", $0.price) } ?? "—")
                        .font(.system(size: 21, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(quote.map { String(format: "%+.2f  %+.2f%%", $0.change, $0.changePercent) } ?? "等待行情")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                }
                .foregroundStyle(movement)
            }
            VStack(spacing: 4) {
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Text(symbol.id.uppercased())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                        Button(action: remove) { Image(systemName: "xmark.circle") }
                            .font(.system(size: 11))
                            .buttonStyle(.plain)
                            .help("删除这只股票")
                            .accessibilityLabel("删除\(symbol.code)")
                        Spacer(minLength: 0)
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                    metric("量比", value: quote.flatMap(\.volumeRatio).map { String(format: "%.2f", $0) } ?? "—")
                        .help("腾讯行情源量比，单位为倍")
                    metric("振幅", value: quote.flatMap(\.amplitudePercent).map { String(format: "%.2f%%", $0) } ?? "—")
                        .help("腾讯行情源日内振幅，单位为百分比")
                }
                HStack(spacing: 10) {
                    metric("成交量", value: quote.map { DisplayFormat.magnitude($0.volumeLots, unit: "手") } ?? "—")
                    metric("换手率", value: quote.flatMap(\.turnoverPercent).map { String(format: "%.2f%%", $0) } ?? "—")
                    metric("成交额", value: quote.map { DisplayFormat.magnitude($0.amountYuan, unit: "元") } ?? "—")
                }
            }
            .font(.system(size: 10))
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }

    private func metric(_ title: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text(title).frame(width: 30, alignment: .leading)
            Text(value)
                .monospacedDigit()
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }
}

struct WidgetView: View {
    @ObservedObject var store: QuoteStore
    let transparency: () -> Void
    let add: () -> Void
    let pin: () -> Void
    let hide: () -> Void
    @State private var newCode = ""
    @State private var additionError: String?
    @FocusState private var codeFocused: Bool

    private var status: String {
        if let additionError { return additionError }
        if store.symbols.isEmpty { return "添加股票后，每3秒自动刷新" }
        let quoteTime = store.quotes.values.map(\.timestamp).min()
        if store.errorMessage != nil {
            return quoteTime.map { "连接失败 · 上次行情 \(DisplayFormat.chinaTime.string(from: $0))" }
                ?? "连接失败 · 自动重试"
        }
        if !store.unavailable.isEmpty { return "部分股票无可用行情 · 自动刷新" }
        if let quoteTime {
            return "行情 \(DisplayFormat.chinaTime.string(from: quoteTime)) · 3秒刷新"
        }
        if let date = store.lastReceipt {
            return "请求成功 \(DisplayFormat.receiptTime.string(from: date)) · 3秒刷新"
        }
        return "正在连接行情源…"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if store.isAddingStock {
                    TextField("股票代码，回车追加", text: $newCode)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                        .focused($codeFocused)
                        .accessibilityLabel("追加股票代码")
                        .onSubmit(addInline)
                        .onExitCommand { store.isAddingStock = false }
                        .onChange(of: newCode) { _ in additionError = nil }
                        .onAppear {
                            DispatchQueue.main.async {
                                if store.isAddingStock { codeFocused = true }
                            }
                        }
                        .frame(maxWidth: .infinity)
                } else if !store.isAdjustingTransparency {
                    Image(systemName: "chart.xyaxis.line")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(store.isPreview ? "A股行情 · 测试预览" : "A股桌面行情")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                }
                toolButton(store.isAddingStock ? "xmark" : "plus",
                           help: store.isAddingStock ? "收起输入框" : "追加股票") {
                    if store.isAddingStock { store.isAddingStock = false }
                    else { add() }
                }
                toolButton("pin", help: store.isPinned ? "取消置顶" : "置顶", selected: store.isPinned, action: pin)
                if store.isAdjustingTransparency {
                    HStack(spacing: 6) {
                        Slider(value: $store.backgroundTransparency, in: 0...1)
                            .accessibilityLabel("背景透明度")
                            .help("0%毛玻璃，100%全透明；拖动即时生效并自动保存")
                        Text("\(Int((store.backgroundTransparency * 100).rounded()))%")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .frame(width: 30, alignment: .trailing)
                    }
                    .frame(maxWidth: .infinity)
                }
                toolButton(store.isAdjustingTransparency ? "xmark" : "gearshape",
                           help: store.isAdjustingTransparency ? "收起透明度滑条" : "调整背景透明度",
                           action: transparency)
                toolButton("minus", help: "隐藏浮窗（菜单栏可重新显示）", action: hide)
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            Divider().opacity(0.6)
            if store.symbols.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "plus.square.dashed")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.secondary)
                    Text("添加你关注的A股")
                        .font(.system(size: 15, weight: .medium))
                    Text("输入股票代码，即可查看量价信息")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button("添加股票", action: add)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 198)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(store.symbols) { symbol in
                            QuoteRow(symbol: symbol, quote: store.quotes[symbol.id],
                                     failed: store.errorMessage != nil,
                                     unavailable: store.unavailable.contains(symbol.id),
                                     remove: { store.removeSymbol(symbol) })
                            if symbol != store.symbols.last { Divider().padding(.horizontal, 16).opacity(0.6) }
                        }
                    }
                }
                .frame(height: min(CGFloat(store.symbols.count) * quoteRowHeight, 570))
            }
            Divider().opacity(0.6)
            HStack(spacing: 6) {
                Circle()
                    .fill(additionError != nil || store.errorMessage != nil || !store.unavailable.isEmpty ? Color.orange
                          : store.lastReceipt != nil ? Color.green : Color.secondary)
                    .frame(width: 5, height: 5)
                Text(status).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: { store.refresh() }) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(store.isRefreshing || store.symbols.isEmpty)
                .help("立即刷新")
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .frame(height: 31)
            .help(additionError ?? store.errorMessage ?? "腾讯公开行情 · 成交量与成交额为当日累计；底部行情时间取列表最早一条，北京时间。最近接收：\(store.lastReceipt.map { DisplayFormat.chinaTime.string(from: $0) } ?? "—")")
        }
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.10), lineWidth: 1))
        .onExitCommand {
            store.isAddingStock = false
            store.isAdjustingTransparency = false
        }
        .onChange(of: store.isAddingStock) { adding in
            if !adding { codeFocused = false; newCode = ""; additionError = nil }
        }
    }

    private func addInline() {
        do {
            try store.addSymbols(newCode)
            newCode = ""
            additionError = nil
            codeFocused = true
        } catch { additionError = error.localizedDescription }
    }

    private func toolButton(_ symbol: String, help: String, selected: Bool = false,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: selected ? "pin.fill" : symbol)
                .font(.system(size: 12))
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

final class DesktopPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var store: QuoteStore!
    private var panel: DesktopPanel!
    private var glassView: NSVisualEffectView?
    private var statusItem: NSStatusItem!
    private var pinItem: NSMenuItem!
    private var subscriptions: [AnyCancellable] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previewDomain: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        let preview = arguments.firstIndex(of: "--preview").flatMap { index in
            index + 1 < arguments.count ? arguments[index + 1] : nil
        }
        let defaults: UserDefaults
        if preview != nil {
            let domain = "cn.local.AShareDesktop.preview.\(UUID().uuidString)"
            previewDomain = domain
            defaults = UserDefaults(suiteName: domain)!
        } else { defaults = .standard }
        store = QuoteStore(defaults: defaults, preview: preview)
        createApplicationMenu()
        createMenu()
        createPanel()
        subscriptions.append(store.$symbols.sink { [weak self] _ in
            DispatchQueue.main.async { self?.resizePanel() }
        })
        subscriptions.append(store.$backgroundTransparency.sink { [weak self] value in
            self?.applyTransparency(value)
        })
        let center = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.willSleepNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.suspend() }
        })
        workspaceObservers.append(center.addObserver(forName: NSWorkspace.didWakeNotification,
                                                      object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.store.resume() }
        })
        store.start()
        panel.orderFrontRegardless()
    }

    private func createMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "chart.xyaxis.line", accessibilityDescription: "A股桌面行情")
        statusItem.button?.toolTip = "A股桌面行情"
        let menu = NSMenu()
        addItem("显示浮窗", action: #selector(showPanel), to: menu)
        addItem("隐藏浮窗", action: #selector(hidePanel), to: menu)
        menu.addItem(.separator())
        addItem("添加股票…", action: #selector(addStock), to: menu)
        addItem("背景透明度", action: #selector(toggleTransparency), to: menu)
        addItem("立即刷新", action: #selector(refresh), to: menu)
        pinItem = addItem("浮窗置顶", action: #selector(togglePin), to: menu)
        pinItem.state = store.isPinned ? .on : .off
        menu.addItem(.separator())
        addItem("退出A股桌面行情", action: #selector(quit), key: "q", to: menu)
        statusItem.menu = menu
    }

    private func createApplicationMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        addItem("退出A股桌面行情", action: #selector(quit), key: "q", to: appMenu)
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let editItem = NSMenuItem(title: "编辑", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"),
                                     ("复制", "copy:", "c"), ("粘贴", "paste:", "v"),
                                     ("全选", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    @discardableResult
    private func addItem(_ title: String, action: Selector, key: String = "", to menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    private func createPanel() {
        panel = DesktopPanel(contentRect: NSRect(x: 0, y: 0, width: 370, height: 280),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "A股桌面行情"
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.level = store.isPinned ? .floating : .normal
        let surface = NSView()
        surface.wantsLayer = true
        surface.layer?.cornerRadius = 16
        surface.layer?.masksToBounds = true
        surface.layer?.backgroundColor = NSColor.clear.cgColor
        let glass = NSVisualEffectView()
        glass.material = .hudWindow
        glass.blendingMode = .behindWindow
        glass.state = .active
        glassView = glass
        glass.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(glass)
        let host = TransparentHostingView(rootView: WidgetView(store: store,
                                                               transparency: { [weak self] in self?.toggleTransparency() },
                                                               add: { [weak self] in self?.addStock() },
                                                               pin: { [weak self] in self?.togglePin() },
                                                               hide: { [weak self] in self?.hidePanel() }))
        host.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(host)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            glass.topAnchor.constraint(equalTo: surface.topAnchor),
            glass.bottomAnchor.constraint(equalTo: surface.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: surface.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: surface.trailingAnchor),
            host.topAnchor.constraint(equalTo: surface.topAnchor),
            host.bottomAnchor.constraint(equalTo: surface.bottomAnchor)
        ])
        panel.contentView = surface
        applyTransparency(store.backgroundTransparency)
        resizePanel()
        if let x = store.defaults.object(forKey: "positionX") as? Double,
           let y = store.defaults.object(forKey: "positionY") as? Double {
            panel.setFrameOrigin(NSPoint(x: x, y: y))
            keepOnScreen()
        } else if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.maxX - panel.frame.width - 24,
                                         y: frame.maxY - panel.frame.height - 24))
        }
        panel.delegate = self
    }

    private func resizePanel() {
        guard panel != nil else { return }
        let rowsHeight = store.symbols.isEmpty ? 198 : min(CGFloat(store.symbols.count) * quoteRowHeight, 570)
        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: 370, height: 81 + rowsHeight)
        frame.origin.y = top - frame.height
        panel.setFrame(frame, display: true)
        updateWindowMask()
        keepOnScreen()
    }

    private func applyTransparency(_ value: Double) {
        glassView?.alphaValue = 1 - value
        glassView?.isHidden = value >= 1
        panel?.invalidateShadow()
    }

    private func updateWindowMask() {
        guard let panel, let glassView else { return }
        let size = panel.frame.size
        let mask = NSImage(size: size)
        mask.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 16, yRadius: 16).fill()
        mask.unlockFocus()
        glassView.maskImage = mask
        panel.invalidateShadow()
    }

    private func keepOnScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        var origin = panel.frame.origin
        origin.x = max(visible.minX, min(origin.x, visible.maxX - panel.frame.width))
        origin.y = max(visible.minY, min(origin.y, visible.maxY - panel.frame.height))
        panel.setFrameOrigin(origin)
    }

    func windowDidMove(_ notification: Notification) {
        guard notification.object as? NSWindow === panel else { return }
        store.defaults.set(panel.frame.origin.x, forKey: "positionX")
        store.defaults.set(panel.frame.origin.y, forKey: "positionY")
    }

    @objc private func showPanel() { keepOnScreen(); panel.orderFrontRegardless() }
    @objc private func hidePanel() { panel.orderOut(nil) }
    @objc private func refresh() { store.refresh() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func addStock() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.isAdjustingTransparency = false
        store.isAddingStock = true
    }

    @objc private func togglePin() {
        store.isPinned.toggle()
        panel.level = store.isPinned ? .floating : .normal
        pinItem.state = store.isPinned ? .on : .off
        panel.orderFrontRegardless()
    }

    @objc private func toggleTransparency() {
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        store.isAddingStock = false
        store.isAdjustingTransparency.toggle()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        if let previewDomain { store.defaults.removePersistentDomain(forName: previewDomain) }
    }
}
