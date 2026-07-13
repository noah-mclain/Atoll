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
import SwiftUI

/// "Live" album art: a slowly-orbiting glow built from the artwork's own
/// dominant colors, plus a gentle breathing pulse on the art while music is
/// playing. Entirely local — no Apple Music motion-artwork API involved, so
/// it works for every source (Spotify, YouTube Music, …) and costs nothing.
struct LiveAlbumArtGlow: View {
    let artwork: NSImage
    let isPlaying: Bool

    @State private var rotate = false
    @State private var colors: [Color] = []

    var body: some View {
        Circle()
            .fill(
                AngularGradient(
                    colors: displayColors + [displayColors.first ?? .clear],
                    center: .center
                )
            )
            .scaleEffect(1.15)
            .rotationEffect(.degrees(rotate ? 360 : 0))
            .blur(radius: 32)
            .opacity(isPlaying ? 0.55 : 0)
            .animation(.easeInOut(duration: 0.8), value: isPlaying)
            .onAppear { startSpinning() }
            .onChange(of: isPlaying) { _, playing in
                if playing { startSpinning() }
            }
            .onChange(of: artwork) { _, newArtwork in
                colors = newArtwork.dominantColors()
            }
            .task {
                colors = artwork.dominantColors()
            }
            .allowsHitTesting(false)
    }

    private var displayColors: [Color] {
        colors.isEmpty ? [.purple, .blue, .pink] : colors
    }

    private func startSpinning() {
        rotate = false
        withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) {
            rotate = true
        }
    }
}

/// Breathing pulse applied to the artwork itself while playing.
struct LiveAlbumArtPulse: ViewModifier {
    let isPlaying: Bool

    @State private var breathe = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isPlaying && breathe ? 1.015 : 1.0)
            .onAppear { restart() }
            .onChange(of: isPlaying) { _, _ in restart() }
    }

    private func restart() {
        breathe = false
        guard isPlaying else { return }
        withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
            breathe = true
        }
    }
}

extension View {
    func liveAlbumArtPulse(isPlaying: Bool) -> some View {
        modifier(LiveAlbumArtPulse(isPlaying: isPlaying))
    }
}

// MARK: - Dominant color extraction

extension NSImage {
    /// Downsamples the image to a tiny bitmap and averages each quadrant,
    /// yielding four representative colors. Cheap enough to run on artwork
    /// changes without caching.
    func dominantColors() -> [Color] {
        let sampleSize = 8
        guard
            let tiff = tiffRepresentation,
            let source = NSBitmapImageRep(data: tiff),
            let small = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: sampleSize,
                pixelsHigh: sampleSize,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        else { return [] }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: small) {
            NSGraphicsContext.current = context
            source.draw(in: NSRect(x: 0, y: 0, width: sampleSize, height: sampleSize))
        }
        NSGraphicsContext.restoreGraphicsState()

        let half = sampleSize / 2
        let quadrants: [(Int, Int)] = [(0, 0), (half, 0), (half, half), (0, half)]
        return quadrants.compactMap { (originX, originY) in
            averageColor(of: small, x: originX, y: originY, size: half)
        }
    }

    private func averageColor(of rep: NSBitmapImageRep, x: Int, y: Int, size: Int) -> Color? {
        var totalR = 0.0, totalG = 0.0, totalB = 0.0
        var count = 0.0
        for px in x..<(x + size) {
            for py in y..<(y + size) {
                guard let c = rep.colorAt(x: px, y: py) else { continue }
                totalR += Double(c.redComponent)
                totalG += Double(c.greenComponent)
                totalB += Double(c.blueComponent)
                count += 1
            }
        }
        guard count > 0 else { return nil }
        // Nudge saturation up so washed-out covers still produce a visible glow.
        let base = NSColor(
            red: totalR / count,
            green: totalG / count,
            blue: totalB / count,
            alpha: 1
        ).usingColorSpace(.deviceRGB) ?? .systemPurple
        let boosted = NSColor(
            hue: base.hueComponent,
            saturation: min(1, base.saturationComponent * 1.4 + 0.1),
            brightness: min(1, base.brightnessComponent * 1.1 + 0.15),
            alpha: 1
        )
        return Color(nsColor: boosted)
    }
}
