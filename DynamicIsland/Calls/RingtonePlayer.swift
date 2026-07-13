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
import AVFoundation
import Foundation

/// Plays a per-source ringtone in a loop while a call is ringing. Stops on
/// `.stop()` or deinit. Falls back to a bundled / system sound when the user
/// hasn't picked a custom file.
@MainActor
final class RingtonePlayer {

    private var player: AVAudioPlayer?

    deinit { player?.stop() }

    func play(for source: CallSource) {
        let url = resolveURL(for: source)
        guard let url, let player = try? AVAudioPlayer(contentsOf: url) else {
            // Fall back to a system NSSound if everything else is missing.
            NSSound(named: CallSettings.shared.fallbackRingtoneName)?.play()
            return
        }
        self.player = player
        player.numberOfLoops = -1
        player.volume = Float(CallSettings.shared.ringtoneVolume)
        player.prepareToPlay()
        player.play()
    }

    func stop() {
        player?.stop()
        player = nil
    }

    // MARK: - Resolution

    private func resolveURL(for source: CallSource) -> URL? {
        switch source {
        case .facetime:
            return CallSettings.shared.facetimeRingtoneURL ?? Self.systemFallback()
        case .phone:
            return CallSettings.shared.phoneRingtoneURL ?? Self.systemFallback()
        case .discord:
            return CallSettings.shared.discordRingtoneURL ?? Self.systemFallback()
        case .voip:
            return CallSettings.shared.facetimeRingtoneURL ?? Self.systemFallback()
        }
    }

    private static func systemFallback() -> URL? {
        let candidates = [
            "/System/Library/Sounds/Glass.aiff",
            "/System/Library/Sounds/Ping.aiff",
            "/System/Library/Sounds/Purr.aiff",
        ]
        return candidates
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Plays per-app notification sounds. Separate from the ringtone player so a
/// chime can fire without disrupting an active call.
@MainActor
final class SoundPlayer {
    static let shared = SoundPlayer()
    private var player: AVAudioPlayer?

    private init() {}

    func playNotificationSound(for source: NotificationAppSource) {
        guard NotificationSettings.shared.notificationVolume > 0 else { return }

        if let custom = NotificationSettings.shared.soundURL(for: source),
           let player = try? AVAudioPlayer(contentsOf: custom) {
            self.player = player
            player.volume = Float(NotificationSettings.shared.notificationVolume)
            player.play()
            return
        }
        NSSound(named: "Funk")?.play()
    }
}
