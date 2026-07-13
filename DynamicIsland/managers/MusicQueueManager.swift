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
import Combine
import Foundation

struct QueueTrack: Identifiable, Equatable {
    let id: Int          // Music.app database ID — stable across queue shifts
    let playlistIndex: Int
    let name: String
    let artist: String
    let album: String

    static func == (lhs: QueueTrack, rhs: QueueTrack) -> Bool {
        lhs.id == rhs.id && lhs.playlistIndex == rhs.playlistIndex
    }
}

/// Fetches the "up next" tracks for Apple Music by reading the current
/// playlist context via AppleScript.
///
/// Music.app does not expose its real Up Next queue to AppleScript, so this
/// derives the queue from the current container: the tracks that follow the
/// current one in `current playlist`. That matches the real queue whenever
/// the user is playing an album / playlist front-to-back (shuffle changes
/// the true order, and radio streams have no container at all — both cases
/// simply yield an empty list, which the UI shows as "queue unavailable").
@MainActor
final class MusicQueueManager: ObservableObject {

    static let shared = MusicQueueManager()

    @Published private(set) var upNext: [QueueTrack] = []
    @Published private(set) var isLoading = false
    @Published private(set) var lastRefreshed: Date?

    /// How many upcoming tracks to surface in the popover.
    private static let fetchLimit = 10
    private static let fieldSeparator = "||"

    private var artworkCache: [Int: NSImage] = [:]
    private var refreshTimer: Timer?

    private init() {}

    // MARK: - Refresh lifecycle

    /// Begin periodic refresh while the queue popover is visible.
    func startObserving() {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                MusicQueueManager.shared.refresh()
            }
        }
    }

    func stopObserving() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        guard MusicManager.shared.bundleIdentifier == "com.apple.Music" else {
            upNext = []
            return
        }
        isLoading = upNext.isEmpty
        Task {
            let tracks = await Self.fetchUpNext()
            self.upNext = tracks
            self.isLoading = false
            self.lastRefreshed = Date()
            self.pruneArtworkCache(keeping: tracks.map(\.id))
        }
    }

    // MARK: - Playback

    func play(_ track: QueueTrack) {
        let script = """
        tell application "Music"
            try
                play (first track of current playlist whose database ID is \(track.id))
            end try
        end tell
        """
        Task {
            try? await AppleScriptHelper.executeVoid(script)
            try? await Task.sleep(nanoseconds: 400_000_000)
            self.refresh()
        }
    }

    // MARK: - Artwork

    func artwork(for track: QueueTrack) async -> NSImage? {
        if let cached = artworkCache[track.id] { return cached }

        let script = """
        tell application "Music"
            try
                set t to (first track of current playlist whose database ID is \(track.id))
                return data of artwork 1 of t
            on error
                return ""
            end try
        end tell
        """
        guard
            let descriptor = try? await AppleScriptHelper.execute(script),
            case let data = descriptor.data,
            data.count > 32,
            let image = NSImage(data: data)
        else { return nil }

        artworkCache[track.id] = image
        return image
    }

    private func pruneArtworkCache(keeping ids: [Int]) {
        let keep = Set(ids)
        artworkCache = artworkCache.filter { keep.contains($0.key) }
    }

    // MARK: - AppleScript queue fetch

    private static func fetchUpNext() async -> [QueueTrack] {
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            try
                set cp to current playlist
                set curIdx to index of current track
                set totalCount to count of tracks of cp
                if curIdx ≥ totalCount then return ""
                set maxIdx to curIdx + \(fetchLimit)
                if maxIdx > totalCount then set maxIdx to totalCount
                set out to ""
                repeat with i from (curIdx + 1) to maxIdx
                    set t to track i of cp
                    set out to out & i & "\(fieldSeparator)" & (name of t) & "\(fieldSeparator)" & (artist of t) & "\(fieldSeparator)" & (album of t) & "\(fieldSeparator)" & (database ID of t) & linefeed
                end repeat
                return out
            on error
                return ""
            end try
        end tell
        """

        guard
            let descriptor = try? await AppleScriptHelper.execute(script),
            let raw = descriptor.stringValue,
            !raw.isEmpty
        else { return [] }

        return raw
            .split(separator: "\n")
            .compactMap { line -> QueueTrack? in
                let parts = line.components(separatedBy: fieldSeparator)
                guard
                    parts.count == 5,
                    let index = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                    let dbID = Int(parts[4].trimmingCharacters(in: .whitespaces))
                else { return nil }
                return QueueTrack(
                    id: dbID,
                    playlistIndex: index,
                    name: parts[1],
                    artist: parts[2],
                    album: parts[3]
                )
            }
    }
}
