import AppKit
import SwiftUI

enum LaunchMode {
    case menu
    case preview
    case sample

    static var current: LaunchMode {
        let args = CommandLine.arguments
        if args.contains("--sample") { return .sample }
        if args.contains("--preview") { return .preview }
        return .menu
    }
}

final class UsageStore: ObservableObject {
    @Published private(set) var agents: [UsageAgent] = []
    var onAgentsChange: (([UsageAgent]) -> Void)?
    private var lastSnapshotAt: Date?
    private var inFlight: Task<Void, Never>?
    /// Set when a refresh is asked for while one is running. The running one may already be past
    /// the change that prompted it (a provider folder dropped in mid-scan), so run one more.
    private var refreshPending = false
    /// Registry order for the refresh in flight. Rows are always published in this order,
    /// whichever source happens to answer first.
    private var refreshOrder: [String] = []
    private let networkEnabled: Bool

    /// How old the last good reading may be before opening the menu fetches a new one.
    static let staleAfter: TimeInterval = 60

    init(networkEnabled: Bool) {
        self.networkEnabled = networkEnabled
    }

    func showSample() {
        agents = SampleUsage.agents
        lastSnapshotAt = Date()
        onAgentsChange?(agents)
    }

    func refresh() {
        guard networkEnabled else { return }
        guard inFlight == nil else {
            refreshPending = true
            return
        }
        inFlight = Task { [weak self] in
            guard let self else { return }
            // Re-read the registry every refresh: a provider folder added since the last one is
            // picked up here, with no restart.
            let sources = AgentRegistry.sources()
            let order = sources.map(\.id)
            await MainActor.run { self.begin(order: order) }
            // All at once, each row landing as soon as its source answers: one slow provider no
            // longer holds up the others, and a script that runs to its 20s limit costs 20s, not
            // 20s plus everything queued behind it.
            await withTaskGroup(of: UsageAgent.self) { group in
                for source in sources {
                    group.addTask { await source.load() }
                }
                for await agent in group {
                    await MainActor.run { self.publish(agent) }
                }
            }
            await MainActor.run { self.finish() }
        }
    }

    func refreshIfStale() {
        // A refresh already running is as fresh as this gets; do not queue another behind it.
        guard networkEnabled, inFlight == nil else { return }
        if let lastSnapshotAt, Date().timeIntervalSince(lastSnapshotAt) < Self.staleAfter {
            return
        }
        refresh()
    }

    /// Drops agents that left the registry. Everyone else keeps their last row on screen until
    /// the new one arrives, so a refresh never blanks the menu.
    private func begin(order: [String]) {
        refreshOrder = order
        let kept = agents.filter { order.contains($0.id) }
        if kept != agents {
            agents = kept
            onAgentsChange?(agents)
        }
    }

    private func publish(_ agent: UsageAgent) {
        var byID: [String: UsageAgent] = [:]
        for existing in agents where byID[existing.id] == nil {
            byID[existing.id] = existing
        }
        byID[agent.id] = agent
        agents = refreshOrder.compactMap { byID[$0] }
        onAgentsChange?(agents)
    }

    private func finish() {
        if agents.contains(where: { !$0.sessions.isEmpty }) {
            lastSnapshotAt = Date()
        }
        inFlight = nil
        if refreshPending {
            refreshPending = false
            refresh()
        }
    }
}

struct RootView: View {
    @ObservedObject var store: UsageStore
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        MenuBox(agents: store.agents, onOpenSettings: onOpenSettings, onClose: onClose)
            .onAppear { store.refreshIfStale() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let store: UsageStore
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var previewWindow: NSWindow?
    private var pollTimer: Timer?
    /// Runs only while the popover or the preview window is on screen, so a menu left open keeps
    /// its numbers moving instead of showing whatever it opened with.
    private var visibleTimer: Timer?
    private var triggers: RefreshTriggers?
    private var clickMonitor: Any?
    private var escapeMonitor: Any?
    private var activatedForPopover = false
    private var settingsWindow: NSWindow?

    override init() {
        let mode = LaunchMode.current
        store = UsageStore(networkEnabled: mode != .sample)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        installStatusItem()
        switch LaunchMode.current {
        case .sample:
            store.showSample()
            openWindow()
        case .preview:
            store.refresh()
            startPolling()
            startTriggers()
            openWindow()
            startVisibleTimer()
        case .menu:
            store.refresh()
            startPolling()
            startTriggers()
        }
    }

    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit AUB", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let root = NSMenu()
        let item = NSMenuItem()
        item.submenu = appMenu
        root.addItem(item)
        NSApp.mainMenu = root
    }

    private var rootView: RootView {
        RootView(
            store: store,
            onOpenSettings: { [weak self] in self?.openSettingsWindow() },
            onClose: { [weak self] in self?.closePopover(nil) }
        )
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = AgentIcons.menuBar
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 328, height: 200)
        self.popover = popover
        statusItem = item
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 5 * 60, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Wake, network return and provider-folder edits. Never in sample mode, which must not
    /// touch the network.
    private func startTriggers() {
        let triggers = RefreshTriggers { [weak self] in self?.store.refresh() }
        triggers.start()
        self.triggers = triggers
    }

    private func startVisibleTimer() {
        guard LaunchMode.current != .sample, visibleTimer == nil else { return }
        let timer = Timer(timeInterval: UsageStore.staleAfter, repeats: true) { [weak self] _ in
            self?.store.refreshIfStale()
        }
        RunLoop.main.add(timer, forMode: .common)
        visibleTimer = timer
    }

    private func stopVisibleTimer() {
        visibleTimer?.invalidate()
        visibleTimer = nil
    }

    // `.transient` can close the popover without going through `closePopover`, so the timer is
    // stopped here rather than there.
    func popoverDidClose(_ notification: Notification) {
        stopVisibleTimer()
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === previewWindow else { return }
        stopVisibleTimer()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            closePopover(sender)
            return
        }
        store.refreshIfStale()
        NSApp.activate(ignoringOtherApps: true)
        activatedForPopover = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        installDismissMonitors()
        startVisibleTimer()
    }

    private func closePopover(_ sender: Any?, deactivating: Bool = true) {
        removeDismissMonitors()
        popover?.performClose(sender)
        let wasActivated = activatedForPopover
        activatedForPopover = false
        if deactivating, wasActivated {
            NSApp.deactivate()
        }
    }

    private func openSettingsWindow() {
        closePopover(nil, deactivating: false)
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView())
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable]
            window.title = "AUB Settings"
            window.isReleasedWhenClosed = false
            // SettingsView declares minWidth 380 / minHeight 400, so honour that.
            window.setContentSize(NSSize(width: 380, height: 420))
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// `.transient` on its own leaves the popover up when the click lands in another app, which
    /// is not how Wi-Fi or Sound behave. Watch for a click anywhere else, and for Escape.
    ///
    /// A global monitor never sees our own app's events, so clicks inside the popover and on the
    /// status button itself do not reach it; the button's own action handles the toggle.
    private func installDismissMonitors() {
        removeDismissMonitors()
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover(nil)
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            self?.closePopover(nil)
            return nil
        }
    }

    private func removeDismissMonitors() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func openWindow() {
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.title = "AUB"
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(NSSize(width: 328, height: 380))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }
}

@main
struct AgentUsageMain {
    static let delegate = AppDelegate()

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        app.run()
    }
}
