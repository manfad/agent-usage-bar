import XCTest
@testable import AgentUsage

final class RefreshTriggersTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-usage-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    func testAddingAProviderFolderFires() throws {
        let providers = root.appendingPathComponent("providers", isDirectory: true)
        try FileManager.default.createDirectory(at: providers, withIntermediateDirectories: true)
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = ProviderFolderWatcher(directory: providers) { fired.fulfill() }
        watcher.start()
        // FSEvents only reports what happens after the stream starts; give it a beat.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? FileManager.default.createDirectory(
                at: providers.appendingPathComponent("acme", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        wait(for: [fired], timeout: 5)
        withExtendedLifetime(watcher) {}
    }

    /// The providers directory usually does not exist. Creating it a level at a time must still
    /// be noticed once it and a provider inside it appear.
    func testProvidersDirectoryCreatedLaterFires() throws {
        let providers = root
            .appendingPathComponent("agent-usage", isDirectory: true)
            .appendingPathComponent("providers", isDirectory: true)
        let fired = expectation(description: "watcher fired")
        fired.assertForOverFulfill = false
        let watcher = ProviderFolderWatcher(directory: providers) { fired.fulfill() }
        watcher.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            try? FileManager.default.createDirectory(
                at: providers.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            try? FileManager.default.createDirectory(
                at: providers.appendingPathComponent("acme", isDirectory: true),
                withIntermediateDirectories: true
            )
        }
        wait(for: [fired], timeout: 6)
        withExtendedLifetime(watcher) {}
    }
}
