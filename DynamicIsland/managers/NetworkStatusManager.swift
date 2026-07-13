/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Combine
import CoreWLAN
import Foundation
import Network

/// Tracks the Mac's network connectivity via `NWPathMonitor` and exposes a
/// short-lived "connection changed" event for the closed-notch live
/// activity, plus a persistent flag while fully offline.
///
/// SSID note: `CWWiFiClient` only returns the network name when the app has
/// Location permission (macOS 14+). Without it we degrade to a plain
/// "Wi-Fi" label rather than prompting — the HUD is not worth a location
/// permission dialog.
@MainActor
final class NetworkStatusManager: ObservableObject {

    static let shared = NetworkStatusManager()

    enum ConnectionKind: Equatable {
        case wifi
        case wired
        case cellular
        case other
        case offline

        var iconName: String {
            switch self {
            case .wifi:     return "wifi"
            case .wired:    return "cable.connector"
            case .cellular: return "antenna.radiowaves.left.and.right"
            case .other:    return "network"
            case .offline:  return "wifi.slash"
            }
        }
    }

    @Published private(set) var kind: ConnectionKind = .other
    @Published private(set) var networkName: String?
    @Published private(set) var isExpensive = false
    /// True for a few seconds after connectivity changes — drives the HUD.
    @Published private(set) var showChangeEvent = false
    /// True while there is no route to the internet at all.
    @Published private(set) var isOffline = false

    private let monitor = NWPathMonitor()
    private var eventTimer: Timer?
    private var hasReceivedFirstPath = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.handle(path: path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "atoll.network.monitor"))
    }

    private func handle(path: NWPath) {
        let newKind: ConnectionKind
        if path.status != .satisfied {
            newKind = .offline
        } else if path.usesInterfaceType(.wifi) {
            newKind = .wifi
        } else if path.usesInterfaceType(.wiredEthernet) {
            newKind = .wired
        } else if path.usesInterfaceType(.cellular) {
            newKind = .cellular
        } else {
            newKind = .other
        }

        let changed = newKind != kind
        kind = newKind
        isExpensive = path.isExpensive
        isOffline = newKind == .offline
        networkName = newKind == .wifi ? Self.currentSSID() : nil

        // Suppress the HUD for the initial path report at launch; only
        // genuine transitions afterwards deserve attention.
        if changed && hasReceivedFirstPath {
            fireChangeEvent()
        }
        hasReceivedFirstPath = true
    }

    private func fireChangeEvent() {
        showChangeEvent = true
        eventTimer?.invalidate()
        eventTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { _ in
            Task { @MainActor in
                NetworkStatusManager.shared.showChangeEvent = false
            }
        }
    }

    var statusLabel: String {
        switch kind {
        case .wifi:     return networkName ?? "Wi-Fi"
        case .wired:    return "Ethernet"
        case .cellular: return "Cellular"
        case .other:    return "Connected"
        case .offline:  return "No Connection"
        }
    }

    private static func currentSSID() -> String? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        return interface.ssid()
    }
}
