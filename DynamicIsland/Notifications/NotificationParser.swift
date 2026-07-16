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
        guard isBannerShaped(strings) else { return nil }

        // macOS 14–26 Notification Center exposes a banner's text as:
        //   [ "Notification Center", "<App>, <Sender>, <Body>", "<Sender>", "<Body>" ]
        // The first entry is the container title, the second is a combined
        // summary whose first comma-separated field is the app name, and the
        // rest are the isolated sender and body — which we prefer, since a
        // body may itself contain commas.
        let fields = strings
            .map(sanitize)
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare("Notification Center") != .orderedSame }
        guard !fields.isEmpty else { return nil }

        let summaryParts = fields[0].components(separatedBy: ", ")
        let appNameHint = summaryParts.first ?? fields[0]

        // The app icon is usually backed by a file URL into the .app bundle,
        // giving the most reliable identity; fall back to the app-name hint.
        let source: NotificationAppSource
        let bundleID: String
        if let path = findAppPathFromImageChildren(in: window),
           let bundle = Bundle(url: URL(fileURLWithPath: path)),
           let id = bundle.bundleIdentifier {
            source = .from(bundleID: id)
            bundleID = id
        } else {
            source = .from(displayHint: appNameHint)
            bundleID = source.rawValue
        }

        let appName = (source == .generic ? appNameHint : source.displayName)
            .trimmedNonEmpty ?? "Notification"

        // Sender + body: prefer the isolated fields, fall back to splitting
        // the combined summary.
        var senderName: String
        var body: String
        if fields.count >= 3 {
            senderName = fields[1]
            body = fields[2...].filter { !isLikelyActionLabel($0) }.joined(separator: " ")
        } else if summaryParts.count >= 3 {
            senderName = summaryParts[1]
            body = summaryParts[2...].joined(separator: ", ")
        } else if fields.count == 2 {
            senderName = fields[0]
            body = fields[1]
        } else {
            senderName = appName
            body = fields[0]
        }

        let (splitSender, subtitle) = splitSenderAndSubtitle(senderName)
        senderName = splitSender.trimmedNonEmpty ?? appName
        body = clampBody(body)

        let voiceHint = detectVoiceMessage(body: body)
        let displayBody = voiceHint ? voiceMessageDisplayBody(for: source) : body
        let avatar = resolveContactImage(name: senderName)

        return AtollNotification(
            source: source,
            appName: appName,
            bundleID: bundleID.isEmpty ? source.rawValue : bundleID,
            senderName: senderName,
            senderAvatarImage: avatar,
            body: displayBody,
            subtitle: subtitle,
            isVoiceMessage: voiceHint,
            voiceMessageURL: nil,
            timestamp: Date(),
            axBannerRef: window,
            nativeActions: harvestActionButtons(from: window)
        )
    }

    /// Buttons whose press we never mirror: banner chrome, plus Reply (the
    /// quick-reply flow drives that one itself).
    private static let ignoredActionTitles: Set<String> = ["Close", "Clear", "Reply"]

    /// Collects the banner's real action buttons ("Allow", "Don't Allow",
    /// "Mark as Read", …) so ours can press them.
    private static func harvestActionButtons(from window: AXUIElement) -> [NotificationNativeAction] {
        var actions: [NotificationNativeAction] = []
        var queue: [AXUIElement] = [window]
        var visited = 0

        while !queue.isEmpty, visited < 64, actions.count < 4 {
            let element = queue.removeFirst()
            visited += 1

            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            if roleRef as? String == kAXButtonRole {
                var title = ""
                for attr in [kAXTitleAttribute, kAXDescriptionAttribute] {
                    var ref: CFTypeRef?
                    if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
                       let str = ref as? String, !str.isEmpty {
                        title = str
                        break
                    }
                }
                if !title.isEmpty, !ignoredActionTitles.contains(title) {
                    actions.append(NotificationNativeAction(
                        title: title,
                        element: element,
                        axAction: kAXPressAction as String
                    ))
                }
            }

            var childrenRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
               let children = childrenRef as? [AXUIElement] {
                queue.append(contentsOf: children)
            }
        }
        return actions
    }

    /// Strips the bidirectional marks Notification Center injects around
    /// non-Latin app/sender names, plus surrounding whitespace.
    private static func sanitize(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\u{200E}", with: "")
            .replacingOccurrences(of: "\u{200F}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Notifications from noisy apps (e.g. clipboard managers echoing logs)
    /// can carry huge bodies; keep the UI sane.
    private static func clampBody(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 300
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
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

    // MARK: - Shape validation

    /// Rejects windows that clearly aren't notification banners — chiefly the
    /// system menu bar, which some banner hosts vend as an AX child. Real
    /// banners carry a handful of labels; a menu leaks dozens plus tell-tale
    /// system entries.
    private static func isBannerShaped(_ strings: [String]) -> Bool {
        if strings.count > 12 { return false }

        let menuMarkers = [
            "About This Mac", "System Settings", "System Information",
            "Recent Items", "in Finder", "Force Quit", "Hide Others",
        ]
        let looksLikeMenu = strings.contains { candidate in
            menuMarkers.contains { candidate.localizedCaseInsensitiveContains($0) }
        }
        return !looksLikeMenu
    }

    // MARK: - Heuristics

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
            "Mute", "Like", "Decline", "Accept", "Allow", "Don't Allow",
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
