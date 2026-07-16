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

    /// How many upcoming tracks to surface in the queue panel. Five rows are
    /// visible at rest; the remainder scrolls.
    private static let fetchLimit = 15
    private static let fieldSeparator = "||"

    private var artworkCache: [Int: NSImage] = [:]
    private var refreshTimer: Timer?
    /// Chains artwork fetches so only one AppleScript request runs at a
    /// time — the fallback path can scan the whole Library, and up to 10
    /// rows requesting concurrently would fire that many scans at once.
    private var artworkFetchTail: Task<Void, Never>?

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

    // MARK: - Reordering

    /// Live preview while a row is dragged — only mutates the published list.
    func reorderLocally(fromOffsets source: IndexSet, toOffset destination: Int) {
        var reordered = upNext
        reordered.move(fromOffsets: source, toOffset: destination)
        upNext = reordered
    }

    /// Mirrors a finished drag into Music.app. AppleScript can only reorder
    /// real (user) playlists — for album or library playback the move sticks
    /// visually until the next refresh snaps back to Music's actual order.
    func commitMove(of trackID: Int) {
        guard let index = upNext.firstIndex(where: { $0.id == trackID }) else { return }

        let script: String
        if index + 1 < upNext.count {
            let successor = upNext[index + 1]
            script = """
            tell application "Music"
                try
                    set cp to current playlist
                    move (first track of cp whose database ID is \(trackID)) to before (first track of cp whose database ID is \(successor.id))
                end try
            end tell
            """
        } else {
            script = """
            tell application "Music"
                try
                    set cp to current playlist
                    move (first track of cp whose database ID is \(trackID)) to end of cp
                end try
            end tell
            """
        }
        Task {
            try? await AppleScriptHelper.executeVoid(script)
            try? await Task.sleep(nanoseconds: 600_000_000)
            self.refresh()
        }
    }

    // MARK: - Artwork

    func artwork(for track: QueueTrack) async -> NSImage? {
        if let cached = artworkCache[track.id] { return cached }

        // Chain onto the previous fetch so at most one AppleScript artwork
        // request is in flight — the Library fallback below can scan the
        // whole library, and firing that concurrently for every visible row
        // would be wasteful.
        let previousTail = artworkFetchTail
        let fetch = Task<NSImage?, Never> { [weak self] in
            await previousTail?.value
            guard let self else { return nil }
            return await self.fetchArtworkFromMusicApp(for: track)
        }
        artworkFetchTail = Task { _ = await fetch.value }
        return await fetch.value
    }

    private func fetchArtworkFromMusicApp(for track: QueueTrack) async -> NSImage? {
        // Re-check the cache: the fetch we just waited on may have already
        // populated this track's artwork.
        if let cached = artworkCache[track.id] { return cached }

        // Match the now-playing fetch: `raw data` yields decodable image
        // bytes, whereas `data` returns a typed descriptor NSImage can't parse.
        // Look the track up by database ID in the current playlist first, then
        // fall back to the Library (covers album-derived queue entries that
        // have no current-playlist context).
        let script = """
        tell application "Music"
            try
                try
                    set t to (first track of current playlist whose database ID is \(track.id))
                on error
                    set t to (first track of playlist "Library" whose database ID is \(track.id))
                end try
                return raw data of artwork 1 of t
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
