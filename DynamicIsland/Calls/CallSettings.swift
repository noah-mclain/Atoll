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
    // MARK: Calls
    static let enableCallForwarding = Key<Bool>("enableCallForwarding", default: true)
    static let enableFacetimeCalls = Key<Bool>("enableFacetimeCalls", default: true)
    static let enablePhoneCalls = Key<Bool>("enablePhoneCalls", default: true)
    static let enableDiscordCalls = Key<Bool>("enableDiscordCalls", default: true)
    static let enableVoipCalls = Key<Bool>("enableVoipCalls", default: true)
    static let facetimeRingtonePath = Key<String?>("facetimeRingtonePath", default: nil)
    static let phoneRingtonePath = Key<String?>("phoneRingtonePath", default: nil)
    static let discordRingtonePath = Key<String?>("discordRingtonePath", default: nil)
    static let callRingtoneVolume = Key<Double>("callRingtoneVolume", default: 1.0)
    static let callFallbackRingtoneName = Key<String>("callFallbackRingtoneName", default: "Glass")
    static let callAutoDeclineAfterSeconds = Key<Int>("callAutoDeclineAfterSeconds", default: 0)
}

@MainActor
final class CallSettings: ObservableObject {
    static let shared = CallSettings()

    private init() {}

    var enabled: Bool {
        get { Defaults[.enableCallForwarding] }
        set { Defaults[.enableCallForwarding] = newValue }
    }

    var ringtoneVolume: Double {
        get { Defaults[.callRingtoneVolume] }
        set { Defaults[.callRingtoneVolume] = max(0, min(1, newValue)) }
    }

    var fallbackRingtoneName: String {
        Defaults[.callFallbackRingtoneName]
    }

    var autoDeclineAfterSeconds: Int {
        get { Defaults[.callAutoDeclineAfterSeconds] }
        set { Defaults[.callAutoDeclineAfterSeconds] = max(0, newValue) }
    }

    func isEnabled(for category: CallSourceCategory) -> Bool {
        guard Defaults[.enableCallForwarding] else { return false }
        switch category {
        case .facetime: return Defaults[.enableFacetimeCalls]
        case .phone:    return Defaults[.enablePhoneCalls]
        case .discord:  return Defaults[.enableDiscordCalls]
        case .voip:     return Defaults[.enableVoipCalls]
        }
    }

    func setEnabled(_ enabled: Bool, for category: CallSourceCategory) {
        switch category {
        case .facetime: Defaults[.enableFacetimeCalls] = enabled
        case .phone:    Defaults[.enablePhoneCalls] = enabled
        case .discord:  Defaults[.enableDiscordCalls] = enabled
        case .voip:     Defaults[.enableVoipCalls] = enabled
        }
    }

    var facetimeRingtoneURL: URL? {
        get { ringtoneURL(for: Defaults[.facetimeRingtonePath]) }
        set { Defaults[.facetimeRingtonePath] = newValue?.path }
    }

    var phoneRingtoneURL: URL? {
        get { ringtoneURL(for: Defaults[.phoneRingtonePath]) }
        set { Defaults[.phoneRingtonePath] = newValue?.path }
    }

    var discordRingtoneURL: URL? {
        get { ringtoneURL(for: Defaults[.discordRingtonePath]) }
        set { Defaults[.discordRingtonePath] = newValue?.path }
    }

    private func ringtoneURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
