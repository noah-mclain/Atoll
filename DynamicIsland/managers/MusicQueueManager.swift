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
    /// While true the open notch swaps the calendar panel for the queue.
    @Published private(set) var isQueueVisible = false

    /// How many upcoming tracks to surface in the popover.
    private static let fetchLimit = 10
    private static let fieldSeparator = "||"

    private var artworkCache: [Int: NSImage] = [:]
    private var refreshTimer: Timer?

    private init() {}

    // MARK: - Inline panel visibility

    func toggleQueueVisible() {
        isQueueVisible ? hideQueue() : showQueue()
    }

    func showQueue() {
        isQueueVisible = true
        startObserving()
    }

    func hideQueue() {
        guard isQueueVisible else { return }
        isQueueVisible = false
        stopObserving()
    }

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
        // Music.app doesn't expose its true Up Next to AppleScript, so we
        // derive it from the playing container: prefer the current playlist,
        // and fall back to the current track's album (covers single tracks
        // played outside a playlist, which have no `current playlist`). Any
        // AppleScript failure is surfaced as "ERR:<reason>" for the log
        // rather than silently swallowed.
        let script = """
        tell application "Music"
            if player state is stopped then return "ERR:stopped"
            set curTrack to missing value
            try
                set curTrack to current track
            on error
                return "ERR:no current track"
            end try
            set curName to name of curTrack
            set curAlbum to album of curTrack

            -- Preferred source: the current playlist context.
            try
                set cp to current playlist
                set curIdx to index of current track
                set totalCount to count of tracks of cp
                if curIdx < totalCount then
                    set maxIdx to curIdx + \(fetchLimit)
                    if maxIdx > totalCount then set maxIdx to totalCount
                    set out to ""
                    repeat with i from (curIdx + 1) to maxIdx
                        set t to track i of cp
                        set out to out & i & "\(fieldSeparator)" & (name of t) & "\(fieldSeparator)" & (artist of t) & "\(fieldSeparator)" & (album of t) & "\(fieldSeparator)" & (database ID of t) & linefeed
                    end repeat
                    if out is not "" then return out
                end if
            end try

            -- Fallback: remaining tracks of the current album, in order.
            try
                set albumTracks to (every track of playlist "Library" whose album is curAlbum)
                set out to ""
                set past to false
                set added to 0
                repeat with t in albumTracks
                    if past and added < \(fetchLimit) then
                        set out to out & (index of t) & "\(fieldSeparator)" & (name of t) & "\(fieldSeparator)" & (artist of t) & "\(fieldSeparator)" & (album of t) & "\(fieldSeparator)" & (database ID of t) & linefeed
                        set added to added + 1
                    end if
                    if (name of t) is curName then set past to true
                end repeat
                if out is not "" then return out
                return "ERR:no upcoming tracks in album"
            on error errMsg
                return "ERR:" & errMsg
            end try
        end tell
        """

        guard
            let descriptor = try? await AppleScriptHelper.execute(script),
            let raw = descriptor.stringValue,
            !raw.isEmpty
        else {
            #if DEBUG
            print("[AtollQueue] AppleScript returned no result")
            #endif
            return []
        }

        if raw.hasPrefix("ERR:") {
            #if DEBUG
            print("[AtollQueue] \(raw)")
            #endif
            return []
        }

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
