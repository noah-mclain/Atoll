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

/// Music-control slot button that reveals the Apple Music up-next queue in
/// a popover. Mirrors the interaction contract of `AirPlayPickerButton`:
/// hover state is reported to the view model so the notch stays open while
/// the user browses the queue.
struct MusicQueueButton: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var queueManager = MusicQueueManager.shared
    @State private var isPopoverPresented = false
    @State private var isHoveringPopover = false
    @EnvironmentObject private var vm: DynamicIslandViewModel

    var body: some View {
        HoverButton(icon: "list.bullet", iconColor: .white, scale: .medium) {
            isPopoverPresented.toggle()
        }
        .accessibilityLabel("Up Next")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .bottom) {
            MusicQueuePopover(
                queueManager: queueManager,
                onHoverChanged: { hovering in
                    isHoveringPopover = hovering
                    updatePopoverActivity()
                }
            ) {
                isPopoverPresented = false
                isHoveringPopover = false
                updatePopoverActivity()
            }
        }
        .onChange(of: isPopoverPresented) { _, presented in
            if presented {
                queueManager.startObserving()
            } else {
                queueManager.stopObserving()
                isHoveringPopover = false
            }
            updatePopoverActivity()
        }
        .onDisappear {
            queueManager.stopObserving()
            vm.isMediaOutputPopoverActive = false
        }
    }

    private func updatePopoverActivity() {
        vm.isMediaOutputPopoverActive = isPopoverPresented && isHoveringPopover
    }
}

struct MusicQueuePopover: View {
    @ObservedObject var queueManager: MusicQueueManager
    var onHoverChanged: (Bool) -> Void
    var dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.headline)
                .padding(.horizontal, 4)

            if queueManager.isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .controlSize(.small)
                    Spacer()
                }
                .padding(.vertical, 16)
            } else if queueManager.upNext.isEmpty {
                Text("Queue unavailable — play an album or playlist in Apple Music.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .padding(4)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(queueManager.upNext) { track in
                            MusicQueueRow(track: track) {
                                queueManager.play(track)
                                dismiss()
                            }
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 260)
        .padding(12)
        .onHover { hovering in
            onHoverChanged(hovering)
        }
        .onDisappear {
            onHoverChanged(false)
        }
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
