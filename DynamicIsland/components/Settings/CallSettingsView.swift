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

struct CallSettingsView: View {
    @Default(.enableCallForwarding) private var enableCallForwarding
    @Default(.enableFacetimeCalls) private var enableFacetimeCalls
    @Default(.enablePhoneCalls) private var enablePhoneCalls
    @Default(.enableDiscordCalls) private var enableDiscordCalls
    @Default(.enableVoipCalls) private var enableVoipCalls
    @Default(.callRingtoneVolume) private var ringtoneVolume
    @Default(.callAutoDeclineAfterSeconds) private var autoDeclineSeconds
    @Default(.facetimeRingtonePath) private var facetimeRingtonePath
    @Default(.phoneRingtonePath) private var phoneRingtonePath
    @Default(.discordRingtonePath) private var discordRingtonePath

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableCallForwarding) {
                    Text("Show incoming calls in the notch")
                }
            } footer: {
                Text("FaceTime, iPhone-Continuity, Discord, and VoIP calls will appear as a call pill above the notch.")
            }

            Section("Call sources") {
                Defaults.Toggle(key: .enableFacetimeCalls) { Text("FaceTime") }
                Defaults.Toggle(key: .enablePhoneCalls) { Text("iPhone calls (via Continuity)") }
                Defaults.Toggle(key: .enableDiscordCalls) { Text("Discord") }
                Defaults.Toggle(key: .enableVoipCalls) { Text("Other VoIP apps (CallKit)") }
            }

            Section("Ringtone") {
                HStack {
                    Label("Volume", systemImage: "speaker.wave.3")
                    Slider(value: $ringtoneVolume, in: 0...1)
                        .frame(maxWidth: 180)
                    Text("\(Int(ringtoneVolume * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                ringtonePicker(label: "FaceTime ringtone", path: $facetimeRingtonePath)
                ringtonePicker(label: "Phone ringtone", path: $phoneRingtonePath)
                ringtonePicker(label: "Discord ringtone", path: $discordRingtonePath)
            }

            Section("Auto-decline") {
                Picker("Auto-decline after", selection: $autoDeclineSeconds) {
                    Text("Never").tag(0)
                    Text("20 seconds").tag(20)
                    Text("30 seconds").tag(30)
                    Text("60 seconds").tag(60)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func ringtonePicker(label: String, path: Binding<String?>) -> some View {
        HStack {
            Text(label)
            Spacer()
            if let current = path.wrappedValue, !current.isEmpty {
                Text(URL(fileURLWithPath: current).lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [UTType.audio]
                panel.canChooseFiles = true
                panel.canChooseDirectories = false
                if panel.runModal() == .OK {
                    path.wrappedValue = panel.url?.path
                }
            }
            if path.wrappedValue != nil {
                Button("Clear") { path.wrappedValue = nil }
                    .foregroundStyle(.secondary)
            }
        }
    }
}
