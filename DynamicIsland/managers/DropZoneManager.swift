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
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Shows a floating "drop to shelf" target under the notch whenever the
/// user drags files anywhere on screen — the Droppy/Dropover interaction.
///
/// Detection: a global `.leftMouseDragged` monitor plus the shared drag
/// pasteboard. Global monitors never receive events for our own windows,
/// so drags that originate from Atoll's shelf don't trigger the zone. The
/// pasteboard is only inspected when its change count moves, i.e. once per
/// drag session.
@MainActor
final class DropZoneManager: NSObject {

    static let shared = DropZoneManager()

    private var panel: NSPanel?
    private var dragMonitor: Any?
    private var upMonitor: Any?
    private var lastSeenChangeCount = NSPasteboard(name: .drag).changeCount
    private var isFileDragSession = false

    private override init() {
        super.init()
    }

    func start() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            Task { @MainActor in self?.handleDragEvent() }
        }
        upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            Task { @MainActor in self?.handleDragEnded() }
        }
    }

    func stop() {
        if let dragMonitor { NSEvent.removeMonitor(dragMonitor) }
        if let upMonitor { NSEvent.removeMonitor(upMonitor) }
        dragMonitor = nil
        upMonitor = nil
        hidePanel()
    }

    // MARK: - Drag session tracking

    private func handleDragEvent() {
        guard Defaults[.enableDropZone] else { return }

        let dragPasteboard = NSPasteboard(name: .drag)
        let changeCount = dragPasteboard.changeCount

        if changeCount != lastSeenChangeCount {
            lastSeenChangeCount = changeCount
            isFileDragSession = dragPasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )
        }

        if isFileDragSession, panel == nil {
            showPanel()
        }
    }

    private func handleDragEnded() {
        isFileDragSession = false
        // Give an in-flight drop a beat to land on the panel before closing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, !self.isFileDragSession else { return }
            self.hidePanel()
        }
    }

    // MARK: - Panel

    private func showPanel() {
        guard panel == nil else { return }

        let screen = screenWithMouse() ?? NSScreen.main
        guard let screen else { return }

        let size = NSSize(width: 210, height: 84)
        let origin = NSPoint(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.maxY - size.height - 42
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(
            rootView: DropZoneView { [weak self] in
                self?.hidePanel()
            }
        )

        panel.orderFrontRegardless()
        self.panel = panel
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func screenWithMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }
}

// MARK: - Drop target view

private struct DropZoneView: View {
    var dismiss: () -> Void

    @State private var isTargeted = false
    @State private var didDrop = false

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: didDrop ? "checkmark.circle.fill" : "tray.and.arrow.down.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(didDrop ? .green : (isTargeted ? .white : .secondary))
                .contentTransition(.symbolEffect(.replace))
            Text(didDrop ? "Added to shelf" : "Drop to shelf")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(isTargeted || didDrop ? .white : .secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(.black.opacity(isTargeted ? 0.92 : 0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(
                    isTargeted ? Color.white.opacity(0.7) : Color.white.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1.5, dash: didDrop ? [] : [6, 4])
                )
        )
        .padding(6)
        .scaleEffect(isTargeted ? 1.04 : 1.0)
        .animation(.spring(duration: 0.25), value: isTargeted)
        .onDrop(
            of: [.fileURL, .url, .utf8PlainText, .plainText, .data],
            isTargeted: $isTargeted
        ) { providers in
            ShelfStateViewModel.shared.load(providers)
            didDrop = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                dismiss()
            }
            return true
        }
    }
}
