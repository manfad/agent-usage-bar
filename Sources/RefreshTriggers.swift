import AppKit
import CoreServices
import Network

/// Everything outside the poll timer that should make the menu re-read: waking from sleep, the
/// network coming back, and a provider folder being added, removed or edited. Each one calls
/// `onTrigger` on the main queue; the store coalesces overlapping refreshes, so a burst is cheap.
final class RefreshTriggers {
    private let onTrigger: () -> Void
    private var wakeObserver: NSObjectProtocol?
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status?
    private var folderWatcher: ProviderFolderWatcher?

    init(onTrigger: @escaping () -> Void) {
        self.onTrigger = onTrigger
    }

    func start() {
        // Wi-Fi is rarely back the instant the lid opens; a refresh fired then just fails and
        // leaves an error up until the next poll. Give it a few seconds first.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.onTrigger() }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(path.status) }
        }
        monitor.start(queue: DispatchQueue(label: "agent-usage.path-monitor"))
        pathMonitor = monitor

        let watcher = ProviderFolderWatcher(directory: ProviderCatalog.directoryURL()) { [weak self] in
            self?.onTrigger()
        }
        watcher.start()
        folderWatcher = watcher
    }

    /// Only a transition into `.satisfied` counts. The monitor reports the current path as soon
    /// as it starts, which is not news, and a change between two working interfaces is not a
    /// reason to hit every endpoint again.
    private func pathChanged(_ status: NWPath.Status) {
        let previous = lastPathStatus
        lastPathStatus = status
        guard status == .satisfied, let previous, previous != .satisfied else { return }
        onTrigger()
    }

    deinit {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        pathMonitor?.cancel()
    }
}

/// Watches the providers directory so a folder dropped in shows up within a second, not at the
/// next poll. FSEvents covers the whole tree, which catches an edit to a `provider.json` as well
/// as a folder coming or going.
///
/// The directory may not exist yet: most people never create it. Then the nearest existing
/// ancestor is watched instead, non-recursively and cheaply, until the directory appears.
final class ProviderFolderWatcher {
    private let directory: URL
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var ancestorSource: DispatchSourceFileSystemObject?
    private var debounce: DispatchWorkItem?

    init(directory: URL, onChange: @escaping () -> Void) {
        self.directory = directory.standardizedFileURL
        self.onChange = onChange
    }

    func start() {
        arm()
    }

    deinit {
        disarm()
    }

    private func arm() {
        disarm()
        if isDirectory(directory) {
            watchTree()
        } else {
            watchAncestor()
        }
    }

    private func disarm() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        ancestorSource?.cancel()
        ancestorSource = nil
    }

    private func watchTree() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<ProviderFolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        // WatchRoot also reports the directory itself being moved or deleted, so the watch can
        // fall back to the ancestor rather than go quietly deaf.
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return
        }
        self.stream = stream
    }

    /// Watches the deepest ancestor that exists. Any write to it re-arms, which either finds the
    /// providers directory at last or moves one level closer to it.
    private func watchAncestor() {
        var ancestor = directory.deletingLastPathComponent()
        while !isDirectory(ancestor), ancestor.path != "/" {
            ancestor = ancestor.deletingLastPathComponent()
        }
        let fd = open(ancestor.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.changed() }
        source.setCancelHandler { close(fd) }
        source.resume()
        ancestorSource = source
    }

    /// Editors and `cp -R` produce a flurry of events for one change. Wait for them to settle,
    /// then re-arm in case the directory appeared or vanished, and refresh once.
    private func changed() {
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let wasWatchingTree = self.stream != nil
            // Waiting on an ancestor always re-arms, so the watch walks down one level at a time
            // as `~/.config/agent-usage/providers` is created piece by piece.
            if !wasWatchingTree || !self.isDirectory(self.directory) {
                self.arm()
            }
            // Something changed above the providers directory without creating it: nothing to
            // show. Losing the directory does refresh, so its providers leave the menu.
            if !wasWatchingTree && self.stream == nil { return }
            self.onChange()
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
