import ServiceManagement
import SwiftUI

/// Which agents the menu shows and in what order, plus the login-item toggle.
///
/// Order and visibility live in `UserDefaults`; `launchAtLogin` is only ever a mirror of what
/// `SMAppService` reports, so the checkbox can never drift from the real login-item state.
final class AgentPreferences: ObservableObject {
    static let shared = AgentPreferences()

    private enum Key {
        static let order = "agentOrder"
        static let hidden = "hiddenAgents"
    }

    @Published var order: [String] {
        didSet { defaults.set(order, forKey: Key.order) }
    }

    @Published var hidden: Set<String> {
        didSet { defaults.set(Array(hidden).sorted(), forKey: Key.hidden) }
    }

    @Published var launchAtLogin: Bool
    @Published var lastLoginError: String?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.stringArray(forKey: Key.order) ?? []
        // Seed from the registry so a first launch already has a definite order to drag around.
        // Assigning in init does not trip didSet, so nothing is written until the user changes it.
        var seeded = stored
        for id in AgentRegistry.sources().map(\.id) where !seeded.contains(id) {
            seeded.append(id)
        }
        self.order = seeded
        self.hidden = Set(defaults.stringArray(forKey: Key.hidden) ?? [])
        self.launchAtLogin = Self.isAppBundle && SMAppService.mainApp.status == .enabled
    }

    // MARK: - Agent list

    /// A discovered provider names itself, since a folder on a built-in id replaces it. Otherwise
    /// the built-in name, and failing that the id.
    static func displayName(for id: String) -> String {
        if let name = ProviderCatalog.names[id], !name.isEmpty { return name }
        switch id {
        case "grok": return "Grok"
        case "chatgpt": return "ChatGPT"
        case "claude": return "Claude"
        default: return id.capitalized
        }
    }

    /// Drops hidden agents, sorts the rest by `order`, and appends anything `order` has never
    /// heard of in the order it arrived.
    func arranged(_ agents: [UsageAgent]) -> [UsageAgent] {
        var rank: [String: Int] = [:]
        for (offset, id) in order.enumerated() where rank[id] == nil {
            rank[id] = offset
        }
        let visible = agents.filter { !hidden.contains($0.id) }
        var known: [(offset: Int, agent: UsageAgent)] = []
        var unknown: [UsageAgent] = []
        for (offset, agent) in visible.enumerated() {
            if rank[agent.id] != nil {
                known.append((offset, agent))
            } else {
                unknown.append(agent)
            }
        }
        // Ties fall back to arrival order, so the result is stable however Swift sorts.
        let sorted = known.sorted { lhs, rhs in
            let left = rank[lhs.agent.id] ?? Int.max
            let right = rank[rhs.agent.id] ?? Int.max
            if left != right { return left < right }
            return lhs.offset < rhs.offset
        }
        return sorted.map(\.agent) + unknown
    }

    func move(fromOffsets: IndexSet, toOffset: Int, within ids: [String]) {
        var moved = ids
        moved.move(fromOffsets: fromOffsets, toOffset: toOffset)
        // Anything we already knew about but that was not on screen keeps its place at the end.
        let untouched = order.filter { !moved.contains($0) }
        order = moved + untouched
    }

    func setHidden(_ id: String, _ hidden: Bool) {
        if hidden {
            self.hidden.insert(id)
        } else {
            self.hidden.remove(id)
        }
    }

    func isHidden(_ id: String) -> Bool {
        hidden.contains(id)
    }

    // MARK: - Login item

    /// `SMAppService` needs a real bundle to register; the bare `swiftc` binary has none.
    private static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    private static let needsBundle = "Open at login needs the app bundle"

    func refreshLaunchAtLogin() {
        guard Self.isAppBundle else {
            launchAtLogin = false
            return
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ on: Bool) {
        guard Self.isAppBundle else {
            launchAtLogin = false
            lastLoginError = Self.needsBundle
            return
        }
        let previous = launchAtLogin
        launchAtLogin = on
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastLoginError = nil
        } catch {
            launchAtLogin = previous
            lastLoginError = error.localizedDescription
        }
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: AgentPreferences = .shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Open at login", isOn: loginBinding)
                if let error = preferences.lastLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Agents") {
                List {
                    ForEach(agentIDs, id: \.self) { id in
                        row(for: id)
                    }
                    .onMove { from, to in
                        preferences.move(fromOffsets: from, toOffset: to, within: agentIDs)
                    }
                }
                .frame(minHeight: 132)
            }
        }
        .formStyle(.grouped)
        .fontDesign(.rounded)
        .frame(minWidth: 380, minHeight: 400)
        .onAppear { preferences.refreshLaunchAtLogin() }
    }

    /// Ids the user has arranged come first, then anything the registry adds that they have not
    /// seen yet. Ids left over from a removed agent stay listed so they can still be reordered.
    private var agentIDs: [String] {
        var ids: [String] = []
        for id in preferences.order where !ids.contains(id) {
            ids.append(id)
        }
        for id in AgentRegistry.knownIDs() where !ids.contains(id) {
            ids.append(id)
        }
        return ids
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { preferences.launchAtLogin },
            set: { preferences.setLaunchAtLogin($0) }
        )
    }

    private func visibilityBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !preferences.isHidden(id) },
            set: { preferences.setHidden(id, !$0) }
        )
    }

    private func row(for id: String) -> some View {
        let name = AgentPreferences.displayName(for: id)
        return HStack(spacing: 10) {
            icon(for: id)
            Text(name)
            Spacer(minLength: 8)
            reorderButtons(for: id, name: name)
            Toggle("Show \(name)", isOn: visibilityBinding(id))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private func icon(for id: String) -> some View {
        Group {
            if let image = AgentIcons.image(for: id) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
            } else {
                Image(systemName: "circle.dashed")
                    .resizable()
            }
        }
        .frame(width: 16, height: 16)
        .foregroundStyle(.primary)
    }

    /// Drag-to-reorder is invisible until you try it, so each row also carries explicit
    /// up and down buttons.
    private func reorderButtons(for id: String, name: String) -> some View {
        let ids = agentIDs
        let index = ids.firstIndex(of: id)
        return HStack(spacing: 2) {
            Button {
                if let index, index > 0 {
                    preferences.move(fromOffsets: IndexSet(integer: index), toOffset: index - 1, within: ids)
                }
            } label: {
                Image(systemName: "chevron.up")
            }
            .accessibilityLabel("Move \(name) up")
            .disabled((index ?? 0) == 0)

            Button {
                if let index, index < ids.count - 1 {
                    preferences.move(fromOffsets: IndexSet(integer: index), toOffset: index + 2, within: ids)
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .accessibilityLabel("Move \(name) down")
            .disabled((index ?? 0) >= ids.count - 1)
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}
