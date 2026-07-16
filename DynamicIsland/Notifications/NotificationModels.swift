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
import Foundation

// MARK: - App Sources

enum NotificationAppSource: String, Codable, CaseIterable {
    case whatsApp   = "net.whatsapp.WhatsApp"
    case discord    = "com.hnc.Discord"
    case iMessage   = "com.apple.MobileSMS"
    case telegram   = "ru.keepcoder.Telegram"
    case slack      = "com.tinyspeck.slackmacgap"
    case facetime   = "com.apple.FaceTime"
    case mail       = "com.apple.mail"
    case generic    = ""

    static func from(bundleID: String) -> NotificationAppSource {
        return allCases.first { !$0.rawValue.isEmpty && $0.rawValue == bundleID } ?? .generic
    }

    /// Heuristic match for AX-discovered banner identifiers, which sometimes
    /// surface app names instead of bundle IDs (e.g. "WhatsApp" rather than
    /// "net.whatsapp.WhatsApp").
    static func from(displayHint: String) -> NotificationAppSource {
        let lower = displayHint.lowercased()
        if lower.contains("whatsapp")  { return .whatsApp }
        if lower.contains("discord")   { return .discord }
        if lower.contains("messages")  { return .iMessage }
        if lower.contains("telegram")  { return .telegram }
        if lower.contains("slack")     { return .slack }
        if lower.contains("facetime")  { return .facetime }
        if lower == "mail"             { return .mail }
        return .generic
    }

    var displayName: String {
        switch self {
        case .whatsApp:  return "WhatsApp"
        case .discord:   return "Discord"
        case .iMessage:  return "Messages"
        case .telegram:  return "Telegram"
        case .slack:     return "Slack"
        case .facetime:  return "FaceTime"
        case .mail:      return "Mail"
        case .generic:   return "Notification"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .whatsApp:  return NSColor(red: 0.07, green: 0.73, blue: 0.42, alpha: 1)
        case .discord:   return NSColor(red: 0.35, green: 0.40, blue: 0.87, alpha: 1)
        case .iMessage:  return NSColor.systemBlue
        case .telegram:  return NSColor(red: 0.09, green: 0.56, blue: 0.82, alpha: 1)
        case .slack:     return NSColor(red: 0.44, green: 0.11, blue: 0.44, alpha: 1)
        case .facetime:  return NSColor.systemGreen
        case .mail:      return NSColor.systemBlue
        case .generic:   return NSColor.systemGray
        }
    }

    /// Resolves the app icon from the running application matching the bundle ID,
    /// falling back to a path probe and then a system symbol.
    var icon: NSImage? {
        if !rawValue.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rawValue) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)
    }

    var supportsQuickReply: Bool {
        switch self {
        case .whatsApp, .iMessage, .telegram, .slack, .discord: return true
        default: return false
        }
    }

    var supportsVoiceMessage: Bool {
        switch self {
        case .whatsApp, .telegram, .iMessage: return true
        default: return false
        }
    }
}

// MARK: - Native banner actions

/// An action button harvested from the system banner (e.g. "Allow" /
/// "Don't Allow" on a permission notification). Pressing it forwards to the
/// real AX element, so the choice actually fires in the posting app — only
/// valid while the system banner is still alive.
struct NotificationNativeAction: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let element: AXUIElement
    let axAction: String

    static func == (lhs: NotificationNativeAction, rhs: NotificationNativeAction) -> Bool {
        lhs.id == rhs.id
    }

    func perform() {
        AXUIElementPerformAction(element, axAction as CFString)
    }
}

// MARK: - Notification Model

struct AtollNotification: Identifiable, Equatable {
    let id: UUID
    let source: NotificationAppSource
    /// Human app name — the source's display name, or the raw app name from
    /// the banner when the source is unrecognized (e.g. "Maccy").
    let appName: String
    let bundleID: String
    let senderName: String
    let senderAvatarImage: NSImage?
    let body: String
    let subtitle: String?           // group chat name, channel name, etc.
    let isVoiceMessage: Bool
    let voiceMessageURL: URL?
    let timestamp: Date
    /// Reference to the system banner's AXUIElement, used so we can press its
    /// native Reply action without re-opening the source app.
    let axBannerRef: AXUIElement?
    /// Action buttons mirrored from the system banner, pressable from ours.
    let nativeActions: [NotificationNativeAction]

    init(
        id: UUID = UUID(),
        source: NotificationAppSource,
        appName: String? = nil,
        bundleID: String,
        senderName: String,
        senderAvatarImage: NSImage? = nil,
        body: String,
        subtitle: String? = nil,
        isVoiceMessage: Bool = false,
        voiceMessageURL: URL? = nil,
        timestamp: Date = Date(),
        axBannerRef: AXUIElement? = nil,
        nativeActions: [NotificationNativeAction] = []
    ) {
        self.id = id
        self.source = source
        self.appName = appName ?? source.displayName
        self.bundleID = bundleID
        self.senderName = senderName
        self.senderAvatarImage = senderAvatarImage
        self.body = body
        self.subtitle = subtitle
        self.isVoiceMessage = isVoiceMessage
        self.voiceMessageURL = voiceMessageURL
        self.timestamp = timestamp
        self.axBannerRef = axBannerRef
        self.nativeActions = nativeActions
    }

    static func == (lhs: AtollNotification, rhs: AtollNotification) -> Bool {
        lhs.id == rhs.id
    }

    /// The originating app's real icon, resolved from the bundle ID when we
    /// have one (covers unrecognized apps too), falling back to the source's
    /// symbol.
    var appIconImage: NSImage? {
        if !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return source.icon
    }
}
