/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import AppKit
import ApplicationServices
import Contacts
import Foundation

/// Walks a banner's AX tree to identify the source app and extract sender +
/// body text. Designed around the macOS 14/15 banner shape: a window holding
/// an icon image, an app-name label, a sender title, and a body subtitle.
/// Falls back gracefully to a generic notification when shape doesn't match.
enum NotificationParser {

    static func parse(window: AXUIElement) -> AtollNotification? {
        let strings = harvestStrings(from: window)
        guard !strings.isEmpty else { return nil }

        // The app icon is usually backed by a file URL pointing into
        // /Applications/<AppName>.app/.../Icon.icns. That gives us the most
        // reliable bundle-ID hint; if we can't find it, we'll fall back to
        // matching the app-name string in the AX tree.
        let iconAppPath = findAppPathFromImageChildren(in: window)

        let bundleID: String
        let source: NotificationAppSource

        if let path = iconAppPath,
           let bundle = Bundle(url: URL(fileURLWithPath: path)),
           let id = bundle.bundleIdentifier {
            bundleID = id
            source = NotificationAppSource.from(bundleID: id)
        } else if let hintMatch = strings.lazy.compactMap({ inferSource(from: $0) }).first {
            source = hintMatch
            bundleID = source.rawValue
        } else {
            source = .generic
            bundleID = ""
        }

        // Layout heuristics:
        //   strings[0]: app name (often), e.g. "WhatsApp"
        //   strings[1]: sender / title, e.g. "Jamie"
        //   strings[2..]: body text + any reply hints
        // We strip the app-name string from the candidate sender/body if it
        // appears, so we don't echo "WhatsApp · WhatsApp".
        let appName = source.displayName
        var cleaned = strings.filter { $0.caseInsensitiveCompare(appName) != .orderedSame }

        if cleaned.isEmpty { cleaned = strings }

        // For some apps the title pattern is "Sender — Group" or "Sender (n messages)".
        let senderRaw = cleaned.first ?? appName
        let (senderName, subtitle) = splitSenderAndSubtitle(senderRaw)
        let body = cleaned.dropFirst().filter { !isLikelyActionLabel($0) }.joined(separator: " ").trimmedNonEmpty
            ?? (cleaned.count > 1 ? cleaned[1] : "")

        let voiceHint = detectVoiceMessage(body: body)
        let displayBody = voiceHint ? voiceMessageDisplayBody(for: source) : body

        let avatar = resolveContactImage(name: senderName)

        return AtollNotification(
            source: source,
            bundleID: bundleID.isEmpty ? source.rawValue : bundleID,
            senderName: senderName,
            senderAvatarImage: avatar,
            body: displayBody,
            subtitle: subtitle,
            isVoiceMessage: voiceHint,
            voiceMessageURL: nil,
            timestamp: Date(),
            axBannerRef: window
        )
    }

    // MARK: - AX harvesting

    private static func harvestStrings(from window: AXUIElement) -> [String] {
        var bucket: [String] = []
        NotificationObserver.collectStrings(from: window, into: &bucket, depth: 0, limit: 32)
        return bucket
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Some banner Image children expose a `kAXURLAttribute` pointing at the
    /// .app bundle's icon file. If we find one, we can resolve the bundle ID
    /// from disk — that's our most reliable source identifier.
    private static func findAppPathFromImageChildren(in window: AXUIElement) -> String? {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXChildrenAttribute as CFString, &children) == .success
        else { return nil }

        var queue: [AXUIElement] = (children as? [AXUIElement]) ?? []
        var visited = 0
        while !queue.isEmpty, visited < 64 {
            let element = queue.removeFirst()
            visited += 1

            var urlRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXURLAttribute as CFString, &urlRef) == .success,
               let url = urlRef as? URL {
                let path = url.path
                if let appRange = path.range(of: ".app/") {
                    return String(path[..<appRange.upperBound]).dropLast().description
                }
                if path.hasSuffix(".app") {
                    return path
                }
            }

            var nextChildren: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &nextChildren) == .success,
               let nested = nextChildren as? [AXUIElement] {
                queue.append(contentsOf: nested)
            }
        }
        return nil
    }

    // MARK: - Heuristics

    private static func inferSource(from text: String) -> NotificationAppSource? {
        let candidate = NotificationAppSource.from(displayHint: text)
        return candidate == .generic ? nil : candidate
    }

    private static func splitSenderAndSubtitle(_ raw: String) -> (sender: String, subtitle: String?) {
        // Common separators: "Sender — Group", "Sender · Group", "Sender (3 messages)"
        let separators: [Character] = ["—", "·", "•"]
        if let sepIndex = raw.firstIndex(where: { separators.contains($0) }) {
            let sender = raw[..<sepIndex].trimmingCharacters(in: .whitespaces)
            let subtitle = raw[raw.index(after: sepIndex)...].trimmingCharacters(in: .whitespaces)
            return (sender.isEmpty ? raw : sender, subtitle.isEmpty ? nil : subtitle)
        }
        return (raw, nil)
    }

    private static func isLikelyActionLabel(_ s: String) -> Bool {
        // Filter banner action buttons (Reply, Mark as Read, Show, Options, …)
        // which would otherwise leak into the body.
        let actionable: Set<String> = [
            "Reply", "Show", "Mark as Read", "Options", "Close", "Clear",
            "Mute", "Like", "Decline", "Accept",
        ]
        return actionable.contains(s)
    }

    private static func detectVoiceMessage(body: String) -> Bool {
        let lower = body.lowercased()
        return lower.contains("voice message")
            || lower.contains("audio message")
            || body.hasPrefix("🎤")
            || body.hasPrefix("🎵")
    }

    private static func voiceMessageDisplayBody(for source: NotificationAppSource) -> String {
        switch source {
        case .iMessage: return "🎤 Audio message"
        default:        return "🎤 Voice message"
        }
    }

    // MARK: - Contact resolution

    private static func resolveContactImage(name: String) -> NSImage? {
        guard !name.isEmpty else { return nil }
        // Avoid asking Contacts before the user has granted access — calling
        // this without authorization throws and spams the log.
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }

        let store = CNContactStore()
        let predicate = CNContact.predicateForContacts(matchingName: name)
        let keys: [CNKeyDescriptor] = [CNContactImageDataKey as CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys)) ?? []
        for contact in contacts {
            if let data = contact.imageData, let img = NSImage(data: data) {
                return img
            }
        }
        return nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
