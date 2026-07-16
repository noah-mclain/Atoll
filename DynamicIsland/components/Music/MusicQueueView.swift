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
import SwiftUI
import UniformTypeIdentifiers

/// Music-control slot button that swaps the calendar panel of the open
/// notch for the Apple Music up-next queue (and back).
struct MusicQueueButton: View {
    @ObservedObject private var queueManager = MusicQueueManager.shared

    var body: some View {
        HoverButton(
            icon: "list.bullet",
            iconColor: queueManager.isQueueVisible ? .accentColor : .white,
            scale: .medium
        ) {
            withAnimation(.smooth(duration: 0.25)) {
                queueManager.toggleQueueVisible()
            }
        }
        .accessibilityLabel("Up Next")
        .onDisappear {
            queueManager.hideQueue()
        }
    }
}

/// Inline queue panel: header plus the shared reorderable track list. Used
/// in place of the calendar in the open notch, and below the controls in the
/// minimalistic player.
struct MusicQueuePanel: View {
    @ObservedObject var queueManager: MusicQueueManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Up Next")
                    .font(.headline)
                Spacer()
                HoverButton(icon: "xmark", scale: .small) {
                    withAnimation(.smooth(duration: 0.25)) {
                        queueManager.hideQueue()
                    }
                }
                .accessibilityLabel("Close queue")
            }
            .padding(.horizontal, 4)

            if queueManager.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            } else if queueManager.upNext.isEmpty {
                Text("Queue unavailable — play an album or playlist in Apple Music.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(4)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                MusicQueueList(queueManager: queueManager)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Scrollable track list with drag-to-reorder. Rows drag within the list;
/// the drop commits the new order to Music.app (real playlists only — album
/// playback snaps back on the next refresh).
struct MusicQueueList: View {
    @ObservedObject var queueManager: MusicQueueManager

    @State private var draggingID: Int?

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(queueManager.upNext) { track in
                    MusicQueueRow(track: track) {
                        queueManager.play(track)
                    }
                    .opacity(draggingID == track.id ? 0.35 : 1)
                    .onDrag {
                        draggingID = track.id
                        return NSItemProvider(object: String(track.id) as NSString)
                    }
                    .onDrop(of: [.text], delegate: QueueReorderDropDelegate(
                        targetID: track.id,
                        draggingID: $draggingID,
                        queueManager: queueManager
                    ))
                }
            }
        }
    }
}

/// Reorders the published list live as the drag passes over rows, then
/// commits the final position to Music.app on drop.
private struct QueueReorderDropDelegate: DropDelegate {
    let targetID: Int
    @Binding var draggingID: Int?
    let queueManager: MusicQueueManager

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            guard let draggingID, draggingID != targetID,
                  let from = queueManager.upNext.firstIndex(where: { $0.id == draggingID }),
                  let to = queueManager.upNext.firstIndex(where: { $0.id == targetID })
            else { return }
            withAnimation(.smooth(duration: 0.2)) {
                queueManager.reorderLocally(
                    fromOffsets: IndexSet(integer: from),
                    toOffset: to > from ? to + 1 : to
                )
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        MainActor.assumeIsolated {
            if let draggingID {
                queueManager.commitMove(of: draggingID)
            }
            draggingID = nil
        }
        return true
    }
}

private struct MusicQueueRow: View {
    let track: QueueTrack
    let action: () -> Void

    @State private var artwork: NSImage?
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let artwork {
                        Image(nsImage: artwork)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.quaternary)
                            .overlay {
                                Image(systemName: "music.note")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                    }
                }
                .frame(width: 30, height: 30)
                .clipShape(RoundedRectangle(cornerRadius: 4))

                VStack(alignment: .leading, spacing: 1) {
                    Text(track.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(track.artist)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if isHovering {
                    Image(systemName: "play.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovering ? Color.primary.opacity(0.08) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = hovering
        }
        .task(id: track.id) {
            artwork = await MusicQueueManager.shared.artwork(for: track)
        }
    }
}
