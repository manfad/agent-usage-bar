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
    private let networkEnabled: Bool

    init(networkEnabled: Bool) {
        self.networkEnabled = networkEnabled
    }

    func showSample() {
        agents = SampleUsage.agents
        lastSnapshotAt = Date()
        onAgentsChange?(agents)
    }

    func refresh() {
        guard networkEnabled, inFlight == nil else { return }
        inFlight = Task { [weak self] in
            guard let self else { return }
            var next: [UsageAgent] = []
            // Re-read the registry every refresh: a provider folder added since the last one is
            // picked up here, with no restart.
            for source in AgentRegistry.sources() {
                next.append(await source.load())
            }
            let loaded = next
            await MainActor.run {
                self.agents = loaded
                if loaded.contains(where: { !$0.sessions.isEmpty }) {
                    self.lastSnapshotAt = Date()
                }
                self.onAgentsChange?(self.agents)
                self.inFlight = nil
            }
        }
    }

    func refreshIfStale() {
        guard networkEnabled else { return }
        if let lastSnapshotAt, Date().timeIntervalSince(lastSnapshotAt) <= 120 {
            return
        }
        refresh()
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

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store: UsageStore
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var previewWindow: NSWindow?
    private var pollTimer: Timer?
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
            openWindow()
        case .menu:
            store.refresh()
            startPolling()
        }
    }

    private func installMainMenu() {
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit Agent Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
        let host = NSHostingController(rootView: rootView)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = NSSize(width: 328, height: 200)
        self.popover = popover
        statusItem = item
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 15 * 60, repeats: true) { [weak self] _ in
            self?.store.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
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
            window.title = "Agent Usage Settings"
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
        window.title = "Agent Usage"
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
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
