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

extension Defaults.Keys {
    // MARK: Notifications
    static let enabledNotificationApps = Key<Set<String>>(
        "enabledNotificationApps",
        default: Set(NotificationAppSource.allCases
            .filter { $0 != .generic }
            .map { $0.rawValue })
    )
    static let watchAllAppsForNotifications = Key<Bool>("watchAllAppsForNotifications", default: false)
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
