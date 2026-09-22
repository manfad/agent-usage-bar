import AppKit

/// Brand glyphs for the agents we track, plus the menu-bar mark.
///
/// Each glyph is embedded as SVG markup rather than shipped as an asset, so the app stays a
/// single `swiftc`-built binary with no resource bundle. AppKit rasterises the markup through
/// `NSImage(data:)`, and every glyph is flagged `isTemplate` so AppKit and SwiftUI tint it with
/// the current foreground colour instead of the colour baked into the file.
enum AgentIcons {
    /// The template glyph for `agent.id`, or `nil` when we have no artwork for that agent.
    /// A plugin that ships an icon wins, the same way a plugin folder overrides a built-in id.
    static func image(for agentID: String) -> NSImage? {
        if let image = pluginImage(for: agentID) { return image }
        guard let glyph = glyph(for: agentID) else { return nil }
        return image(named: agentID, data: Data(glyph.markup.utf8), side: 24, label: glyph.label)
    }

    /// Brand colour used to tint the glyph on light backgrounds. Grok and OpenAI marks are
    /// black by brand, so only Claude carries a built-in colour (LobeHub's `claude-color`);
    /// plugins name theirs as a hex string in `provider.json`.
    static func brandColor(for agentID: String) -> NSColor? {
        if let hex = ProviderCatalog.chrome(for: agentID)?.color, let color = color(hex: hex) {
            return color
        }
        switch agentID {
        case "claude": return NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        default: return nil
        }
    }

    /// `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or without the hash.
    static func color(hex: String) -> NSColor? {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.allSatisfy(\.isHexDigit) else { return nil }
        let digits: [String]
        switch text.count {
        case 3, 4:
            digits = text.map { "\($0)\($0)" }
        case 6, 8:
            digits = stride(from: 0, to: text.count, by: 2).map { offset in
                let start = text.index(text.startIndex, offsetBy: offset)
                return String(text[start..<text.index(start, offsetBy: 2)])
            }
        default:
            return nil
        }
        let values = digits.compactMap { UInt8($0, radix: 16) }.map { CGFloat($0) / 255 }
        guard values.count == digits.count else { return nil }
        return NSColor(
            srgbRed: values[0],
            green: values[1],
            blue: values[2],
            alpha: values.count == 4 ? values[3] : 1
        )
    }

    /// A plugin's template SVG, keyed on its path and mtime so editing the file shows up without
    /// a restart.
    private static func pluginImage(for agentID: String) -> NSImage? {
        guard let chrome = ProviderCatalog.chrome(for: agentID), let url = chrome.iconURL else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        return image(named: "plugin:\(url.path)#\(stamp)", data: data, side: 24, label: chrome.name)
    }

    /// The robot mark for the status item. macOS ships no `robot` SF Symbol, and the LobeHub
    /// logo collapses into an unreadable silhouette once flattened to a template mask, so this
    /// is a stroked mark in the same spirit: wide head, two eyes, antenna, side ears.
    static var menuBar: NSImage {
        if let image = image(named: "menu-bar", data: Data(robotMarkup.utf8), side: 18, label: "Agent Usage") {
            return image
        }
        let fallback = NSImage(systemSymbolName: "cpu", accessibilityDescription: "Agent Usage")
            ?? NSImage(size: NSSize(width: 18, height: 18))
        fallback.isTemplate = true
        return fallback
    }

    // MARK: - Rendering

    private static let cache = NSCache<NSString, NSImage>()

    private static func image(named name: String, data: Data, side: CGFloat, label: String) -> NSImage? {
        let key = "\(name)@\(side)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        image.size = NSSize(width: side, height: side)
        image.isTemplate = true
        image.accessibilityDescription = label
        cache.setObject(image, forKey: key)
        return image
    }

    private static func glyph(for agentID: String) -> (markup: String, label: String)? {
        switch agentID {
        case "grok": return (grokMarkup, "Grok")
        case "chatgpt": return (chatGPTMarkup, "ChatGPT")
        case "claude": return (claudeMarkup, "Claude")
        default: return nil
        }
    }

    // MARK: - Markup

    /// Grok, from LobeHub's icon set.
    private static let grokMarkup = """
    <svg fill="white" fill-rule="evenodd" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M9.27 15.29l7.978-5.897c.391-.29.95-.177 1.137.272.98 2.369.542 5.215-1.41 7.169-1.951 1.954-4.667 2.382-7.149 1.406l-2.711 1.257c3.889 2.661 8.611 2.003 11.562-.953 2.341-2.344 3.066-5.539 2.388-8.42l.006.007c-.983-4.232.242-5.924 2.75-9.383.06-.082.12-.164.179-.248l-3.301 3.305v-.01L9.267 15.292M7.623 16.723c-2.792-2.67-2.31-6.801.071-9.184 1.761-1.763 4.647-2.483 7.166-1.425l2.705-1.25a7.808 7.808 0 00-1.829-1A8.975 8.975 0 005.984 5.83c-2.533 2.536-3.33 6.436-1.962 9.764 1.022 2.487-.653 4.246-2.34 6.022-.599.63-1.199 1.259-1.682 1.925l7.62-6.815"></path></svg>
    """

    /// OpenAI, from LobeHub's icon set.
    private static let chatGPTMarkup = """
    <svg fill="white" fill-rule="evenodd" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M9.205 8.658v-2.26c0-.19.072-.333.238-.428l4.543-2.616c.619-.357 1.356-.523 2.117-.523 2.854 0 4.662 2.212 4.662 4.566 0 .167 0 .357-.024.547l-4.71-2.759a.797.797 0 00-.856 0l-5.97 3.473zm10.609 8.8V12.06c0-.333-.143-.57-.429-.737l-5.97-3.473 1.95-1.118a.433.433 0 01.476 0l4.543 2.617c1.309.76 2.189 2.378 2.189 3.948 0 1.808-1.07 3.473-2.76 4.163zM7.802 12.703l-1.95-1.142c-.167-.095-.239-.238-.239-.428V5.899c0-2.545 1.95-4.472 4.591-4.472 1 0 1.927.333 2.712.928L8.23 5.067c-.285.166-.428.404-.428.737v6.898zM12 15.128l-2.795-1.57v-3.33L12 8.658l2.795 1.57v3.33L12 15.128zm1.796 7.23c-1 0-1.927-.332-2.712-.927l4.686-2.712c.285-.166.428-.404.428-.737v-6.898l1.974 1.142c.167.095.238.238.238.428v5.233c0 2.545-1.974 4.472-4.614 4.472zm-5.637-5.303l-4.544-2.617c-1.308-.761-2.188-2.378-2.188-3.948A4.482 4.482 0 014.21 6.327v5.423c0 .333.143.571.428.738l5.947 3.449-1.95 1.118a.432.432 0 01-.476 0zm-.262 3.9c-2.688 0-4.662-2.021-4.662-4.519 0-.19.024-.38.047-.57l4.686 2.71c.286.167.571.167.856 0l5.97-3.448v2.26c0 .19-.07.333-.237.428l-4.543 2.616c-.619.357-1.356.523-2.117.523zm5.899 2.83a5.947 5.947 0 005.827-4.756C22.287 18.339 24 15.84 24 13.296c0-1.665-.713-3.282-1.998-4.448.119-.5.19-.999.19-1.498 0-3.401-2.759-5.947-5.946-5.947-.642 0-1.26.095-1.88.31A5.962 5.962 0 0010.205 0a5.947 5.947 0 00-5.827 4.757C1.713 5.447 0 7.945 0 10.49c0 1.666.713 3.283 1.998 4.448-.119.5-.19 1-.19 1.499 0 3.401 2.759 5.946 5.946 5.946.642 0 1.26-.095 1.88-.309a5.96 5.96 0 004.162 1.713z"></path></svg>
    """

    /// Claude, from LobeHub's icon set.
    private static let claudeMarkup = """
    <svg fill="white" fill-rule="evenodd" height="24" viewBox="0 0 24 24" width="24" xmlns="http://www.w3.org/2000/svg"><path d="M4.709 15.955l4.72-2.647.08-.23-.08-.128H9.2l-.79-.048-2.698-.073-2.339-.097-2.266-.122-.571-.121L0 11.784l.055-.352.48-.321.686.06 1.52.103 2.278.158 1.652.097 2.449.255h.389l.055-.157-.134-.098-.103-.097-2.358-1.596-2.552-1.688-1.336-.972-.724-.491-.364-.462-.158-1.008.656-.722.881.06.225.061.893.686 1.908 1.476 2.491 1.833.365.304.145-.103.019-.073-.164-.274-1.355-2.446-1.446-2.49-.644-1.032-.17-.619a2.97 2.97 0 01-.104-.729L6.283.134 6.696 0l.996.134.42.364.62 1.414 1.002 2.229 1.555 3.03.456.898.243.832.091.255h.158V9.01l.128-1.706.237-2.095.23-2.695.08-.76.376-.91.747-.492.584.28.48.685-.067.444-.286 1.851-.559 2.903-.364 1.942h.212l.243-.242.985-1.306 1.652-2.064.73-.82.85-.904.547-.431h1.033l.76 1.129-.34 1.166-1.064 1.347-.881 1.142-1.264 1.7-.79 1.36.073.11.188-.02 2.856-.606 1.543-.28 1.841-.315.833.388.091.395-.328.807-1.969.486-2.309.462-3.439.813-.042.03.049.061 1.549.146.662.036h1.622l3.02.225.79.522.474.638-.079.485-1.215.62-1.64-.389-3.829-.91-1.312-.329h-.182v.11l1.093 1.068 2.006 1.81 2.509 2.33.127.578-.322.455-.34-.049-2.205-1.657-.851-.747-1.926-1.62h-.128v.17l.444.649 2.345 3.521.122 1.08-.17.353-.608.213-.668-.122-1.374-1.925-1.415-2.167-1.143-1.943-.14.08-.674 7.254-.316.37-.729.28-.607-.461-.322-.747.322-1.476.389-1.924.315-1.53.286-1.9.17-.632-.012-.042-.14.018-1.434 1.967-2.18 2.945-1.726 1.845-.414.164-.717-.37.067-.662.401-.589 2.388-3.036 1.44-1.882.93-1.086-.006-.158h-.055L4.132 18.56l-1.13.146-.487-.456.061-.746.231-.243 1.908-1.312-.006.006z"></path></svg>
    """

    /// Status-item robot, drawn to read at 18pt in either menu-bar appearance.
    private static let robotMarkup = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="24" height="24"><g fill="none" stroke="white" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><rect x="3.15" y="6.75" width="17.7" height="12.1" rx="4.3"/><path d="M12 6.75V4.2"/><circle cx="12" cy="2.9" r="1.35" fill="white" stroke="none"/><path d="M1.9 11.3v3M22.1 11.3v3"/><circle cx="8.9" cy="12.3" r="1.5" fill="white" stroke="none"/><circle cx="15.1" cy="12.3" r="1.5" fill="white" stroke="none"/><path d="M10.1 16.1h3.8"/></g></svg>
    """
}
