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
import Foundation

// MARK: - Call Source

enum CallSource: Equatable {
    case facetime(callerName: String, callerImage: NSImage?, isVideo: Bool)
    case phone(callerName: String, callerImage: NSImage?, phoneNumber: String)
    case discord(callerName: String, callerImage: NSImage?, channelName: String, guildName: String?)
    case voip(appBundleID: String, appName: String, callerName: String, callerImage: NSImage?)

    var displayName: String {
        switch self {
        case .facetime(let n, _, _):     return n
        case .phone(let n, _, _):        return n
        case .discord(let n, _, _, _):   return n
        case .voip(_, _, let n, _):      return n
        }
    }

    var callerImage: NSImage? {
        switch self {
        case .facetime(_, let img, _):   return img
        case .phone(_, let img, _):      return img
        case .discord(_, let img, _, _): return img
        case .voip(_, _, _, let img):    return img
        }
    }

    var subtitle: String {
        switch self {
        case .facetime(_, _, let isVideo):
            return isVideo ? "FaceTime Video" : "FaceTime Audio"
        case .phone:
            return "iPhone"
        case .discord(_, _, let channel, let guild):
            return guild.map { "\($0) · #\(channel)" } ?? "#\(channel)"
        case .voip(_, let appName, _, _):
            return appName
        }
    }

    var accentColor: NSColor {
        switch self {
        case .facetime: return .systemGreen
        case .phone:    return .systemGreen
        case .discord:  return NSColor(red: 0.35, green: 0.40, blue: 0.87, alpha: 1)
        case .voip:     return .systemTeal
        }
    }

    var sourceCategory: CallSourceCategory {
        switch self {
        case .facetime: return .facetime
        case .phone:    return .phone
        case .discord:  return .discord
        case .voip:     return .voip
        }
    }

    static func == (lhs: CallSource, rhs: CallSource) -> Bool {
        switch (lhs, rhs) {
        case (.facetime(let l1, _, let l3), .facetime(let r1, _, let r3)):
            return l1 == r1 && l3 == r3
        case (.phone(let l1, _, let l3), .phone(let r1, _, let r3)):
            return l1 == r1 && l3 == r3
        case (.discord(let l1, _, let l3, let l4), .discord(let r1, _, let r3, let r4)):
            return l1 == r1 && l3 == r3 && l4 == r4
        case (.voip(let l1, _, let l3, _), .voip(let r1, _, let r3, _)):
            return l1 == r1 && l3 == r3
        default:
            return false
        }
    }
}

/// Stable category used for settings toggles and feature flags.
enum CallSourceCategory: String, CaseIterable, Codable {
    case facetime
    case phone
    case discord
    case voip
}

// MARK: - Call Model

struct AtollCall: Identifiable, Equatable {
    let id: UUID
    let source: CallSource
    let startedAt: Date
    /// CallKit UUID when the call came in via CXCallObserver (VoIP apps).
    /// `nil` for FaceTime / iPhone-Continuity / Discord, which we observe via
    /// the system notification banner instead.
    var callUUID: UUID?

    init(
        id: UUID = UUID(),
        source: CallSource,
        startedAt: Date = Date(),
        callUUID: UUID? = nil
    ) {
        self.id = id
        self.source = source
        self.startedAt = startedAt
        self.callUUID = callUUID
    }

    static func == (lhs: AtollCall, rhs: AtollCall) -> Bool {
        lhs.id == rhs.id
    }
}
