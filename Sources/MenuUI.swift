import AppKit
import SwiftUI

struct MenuBox: View {
    var agents: [UsageAgent]
    var onOpenSettings: () -> Void = {}
    var onClose: () -> Void = {}

    @ObservedObject var preferences: AgentPreferences = .shared

    /// Past this the list scrolls, so a long agent list cannot outgrow the screen.
    private static let maxListHeight: CGFloat = 420

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            let visible = preferences.arranged(agents)
            if visible.isEmpty {
                Text(agents.isEmpty ? "No usage yet" : "Every agent is hidden")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 14)
            } else {
                AgentList(agents: visible, maxHeight: Self.maxListHeight)
            }

            Divider()
                .padding(.vertical, 10)

            MenuFooter(onOpenSettings: onOpenSettings)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(width: 328)
    }
}

/// Settings and Quit, kept quiet so they never compete with the usage bars.
struct MenuFooter: View {
    var onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            FooterButton(action: onOpenSettings) {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")

            Spacer(minLength: 8)

            FooterButton(action: { NSApp.terminate(nil) }) {
                Text("Quit AUB")
            }
        }
        .font(.system(size: 13, design: .rounded))
    }
}

/// A plain footer control that brightens on hover, the way menu-bar popover rows do.
private struct FooterButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(.plain)
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .onHover { isHovering = $0 }
    }
}

/// The agent rows, scrolling only once they outgrow `maxHeight`. The height is measured from
/// the content so the popover sizes itself to short lists instead of padding them out.
struct AgentList: View {
    var agents: [UsageAgent]
    var maxHeight: CGFloat

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                    if index > 0 {
                        Divider()
                            .padding(.vertical, 14)
                    }
                    AgentComponent(agent: agent)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
                }
            )
        }
        .onPreferenceChange(ContentHeightKey.self) { contentHeight = $0 }
        .frame(height: min(max(contentHeight, 1), maxHeight))
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct AgentComponent: View {
    var agent: UsageAgent

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 7) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    // A two-word name like "OpenAI API" wraps rather than truncating; the
                    // column is deliberately narrow, so the second line is the cheaper cost.
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                AgentIcon(agentID: agent.id)
            }
            .frame(width: 68)

            VStack(alignment: .leading, spacing: 12) {
                if agent.sessions.isEmpty, let reason = agent.unavailableReason {
                    Text(reason)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(agent.sessions) { session in
                    SessionComponent(session: session)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct SessionComponent: View {
    var session: UsageSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.name)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            HStack(alignment: .top, spacing: 6) {
                VStack(spacing: 3) {
                    SessionBar(fraction: session.remainingFraction)
                    // The caption sits centred under the bar, muted, like a hint. A credits row
                    // spells out what was spent as well as the reset, so it gets a second line.
                    Text(session.captionText())
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                }
                Text(session.figureText())
                    .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.primary)
                    // An amount is wider than a percentage, so 34 is a floor, not a cage.
                    .fixedSize()
                    .frame(minWidth: 34, alignment: .trailing)
                    // Centres the digits on the bar, ignoring the caption beneath it.
                    .alignmentGuide(.top) { $0[VerticalAlignment.center] - SessionBar.height / 2 }
            }
        }
    }
}

/// The bar and label show what is left, so they drain as the window is consumed.
func remainingPercent(used: Double) -> Double {
    min(max(100 - used, 0), 100)
}

struct SessionBar: View {
    static let height: CGFloat = 7
    /// How much of the track to fill, or `nil` for a session with nothing to measure against —
    /// the track still draws, so the row keeps its shape.
    var fraction: Double?

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(nsColor: .quaternaryLabelColor))
                Capsule()
                    .fill(Color(nsColor: .systemBlue))
                    .frame(width: fill(in: geo.size.width))
            }
        }
        .frame(height: Self.height)
        .animation(.easeOut(duration: 0.25), value: fraction)
    }

    /// Keeps a non-zero reading legible: below one bar-width it would vanish into the track.
    private func fill(in width: Double) -> Double {
        guard let fraction, fraction > 0 else { return 0 }
        return max(width * min(fraction, 1), 7)
    }
}

struct AgentIcon: View {
    var agentID: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        icon
            .frame(width: 22, height: 22)
            .foregroundStyle(tint)
    }

    /// Brand colour on light backgrounds; plain label colour in dark mode.
    private var tint: Color {
        if colorScheme == .light, let brand = AgentIcons.brandColor(for: agentID) {
            return Color(nsColor: brand)
        }
        return .primary
    }

    @ViewBuilder
    private var icon: some View {
        if let image = AgentIcons.image(for: agentID) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "cpu")
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}
