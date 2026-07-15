/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Defaults
import Foundation

/// How arriving notifications interrupt: fully open the notch, only for a
/// chosen set of apps (others peek), or never open (always a quiet peek).
enum NotificationExpandBehavior: String, Defaults.Serializable, CaseIterable, Identifiable {
    case all
    case selected
    case peekOnly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:      return "All notifications"
        case .selected: return "Selected apps only"
        case .peekOnly: return "Never (peek only)"
        }
    }
}

extension Defaults.Keys {
    // MARK: Notifications
    static let enabledNotificationApps = Key<Set<String>>(
        "enabledNotificationApps",
        default: Set(NotificationAppSource.allCases
            .filter { $0 != .generic }
            .map { $0.rawValue })
    )
    static let watchAllAppsForNotifications = Key<Bool>("watchAllAppsForNotifications", default: true)
    /// Whether a notification opens the notch, or just peeks like the music
    /// live activity.
    static let notificationExpandBehavior = Key<NotificationExpandBehavior>(
        "notificationExpandBehavior", default: .all
    )
    /// Apps whose notifications open the notch when the behavior is `.selected`.
    static let notificationExpandApps = Key<Set<String>>(
        "notificationExpandApps",
        default: Set([NotificationAppSource.whatsApp, .discord, .iMessage, .facetime].map { $0.rawValue })
    )
    static let notificationDisplayDurations = Key<[String: Double]>(
        "notificationDisplayDurations",
        default: [:]
    )
    static let notificationCustomSoundPaths = Key<[String: String]>(
        "notificationCustomSoundPaths",
        default: [:]
    )
    static let notificationVolume = Key<Double>("notificationVolume", default: 0.8)
    static let enableNotificationForwarding = Key<Bool>("enableNotificationForwarding", default: true)
}

/// Read/write facade over the Defaults keys for notifications. Centralizing
/// access here keeps callers free of `Defaults[…]` and string keys, and gives
/// us a single place to add validation if we ever need it.
@MainActor
final class NotificationSettings: ObservableObject {
    static let shared = NotificationSettings()

    private init() {}

    var enabled: Bool {
        get { Defaults[.enableNotificationForwarding] }
        set { Defaults[.enableNotificationForwarding] = newValue }
    }

    var watchAllApps: Bool {
        get { Defaults[.watchAllAppsForNotifications] }
        set { Defaults[.watchAllAppsForNotifications] = newValue }
    }

    var notificationVolume: Double {
        get { Defaults[.notificationVolume] }
        set { Defaults[.notificationVolume] = max(0, min(1, newValue)) }
    }

    func isEnabled(for source: NotificationAppSource) -> Bool {
        guard Defaults[.enableNotificationForwarding] else { return false }
        if source == .generic {
            return Defaults[.watchAllAppsForNotifications]
        }
        return Defaults[.enabledNotificationApps].contains(source.rawValue)
    }

    func setEnabled(_ enabled: Bool, for source: NotificationAppSource) {
        var set = Defaults[.enabledNotificationApps]
        if enabled { set.insert(source.rawValue) } else { set.remove(source.rawValue) }
        Defaults[.enabledNotificationApps] = set
    }

    var expandBehavior: NotificationExpandBehavior {
        get { Defaults[.notificationExpandBehavior] }
        set { Defaults[.notificationExpandBehavior] = newValue }
    }

    /// Whether an arriving notification from `source` should open the notch
    /// (vs. peeking quietly like the music live activity).
    func shouldExpand(for source: NotificationAppSource) -> Bool {
        switch Defaults[.notificationExpandBehavior] {
        case .all:      return true
        case .peekOnly: return false
        case .selected: return Defaults[.notificationExpandApps].contains(source.rawValue)
        }
    }

    func expandsNotch(for source: NotificationAppSource) -> Bool {
        Defaults[.notificationExpandApps].contains(source.rawValue)
    }

    func setExpandsNotch(_ expands: Bool, for source: NotificationAppSource) {
        var set = Defaults[.notificationExpandApps]
        if expands { set.insert(source.rawValue) } else { set.remove(source.rawValue) }
        Defaults[.notificationExpandApps] = set
    }

    func displayDuration(for source: NotificationAppSource) -> Double {
        Defaults[.notificationDisplayDurations][source.rawValue] ?? 5.0
    }

    func setDisplayDuration(_ duration: Double, for source: NotificationAppSource) {
        var map = Defaults[.notificationDisplayDurations]
        map[source.rawValue] = duration
        Defaults[.notificationDisplayDurations] = map
    }

    func soundURL(for source: NotificationAppSource) -> URL? {
        guard let path = Defaults[.notificationCustomSoundPaths][source.rawValue],
              !path.isEmpty
        else { return nil }
        return URL(fileURLWithPath: path)
    }

    func setSoundURL(_ url: URL?, for source: NotificationAppSource) {
        var map = Defaults[.notificationCustomSoundPaths]
        if let url { map[source.rawValue] = url.path }
        else { map.removeValue(forKey: source.rawValue) }
        Defaults[.notificationCustomSoundPaths] = map
    }
}
