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

struct NotificationSettingsView: View {
    @Default(.enableNotificationForwarding) private var enableNotificationForwarding
    @Default(.enabledNotificationApps) private var enabledNotificationApps
    @Default(.watchAllAppsForNotifications) private var watchAllApps
    @Default(.notificationDisplayDurations) private var displayDurations
    @Default(.notificationVolume) private var notificationVolume
    @Default(.notificationExpandBehavior) private var expandBehavior
    @Default(.notificationExpandApps) private var expandApps
    @ObservedObject private var permissionStore = AccessibilityPermissionStore.shared

    private var watchedApps: [NotificationAppSource] {
        NotificationAppSource.allCases.filter { $0 != .generic && $0 != .facetime }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableNotificationForwarding) {
                    Text("Show notifications in the notch")
                }
            } footer: {
                Text("Atoll observes the macOS notification banners and mirrors them inside the notch. Requires Accessibility permission so it can read banner content.")
            }

            if !permissionStore.isAuthorized {
                Section {
                    HStack {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                        VStack(alignment: .leading) {
                            Text("Accessibility permission required")
                                .fontWeight(.semibold)
                            Text("Atoll uses Accessibility to read notification banners. Without it the notch will stay empty.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Grant") {
                            permissionStore.requestAuthorizationPrompt()
                        }
                    }
                }
            }

            Section {
                Picker("Expand the notch", selection: $expandBehavior) {
                    ForEach(NotificationExpandBehavior.allCases) { behavior in
                        Text(behavior.displayName).tag(behavior)
                    }
                }
                if expandBehavior == .selected {
                    ForEach(watchedApps, id: \.rawValue) { source in
                        Toggle(isOn: Binding(
                            get: { expandApps.contains(source.rawValue) },
                            set: { on in
                                var set = expandApps
                                if on { set.insert(source.rawValue) } else { set.remove(source.rawValue) }
                                expandApps = set
                            }
                        )) {
                            Text(source.displayName)
                        }
                    }
                }
            } header: {
                Text("Interruptions")
            } footer: {
                Text("“All” opens the notch for every notification. “Selected apps only” expands for the apps you choose and quietly peeks the rest. “Never” always peeks like the music activity. Incoming calls always expand.")
            }

            Section("Messaging apps") {
                ForEach(watchedApps, id: \.rawValue) { source in
                    appRow(source)
                }
            }

            Section("Sound") {
                HStack {
                    Label("Volume", systemImage: "speaker.wave.2")
                    Slider(value: $notificationVolume, in: 0...1)
                        .frame(maxWidth: 180)
                    Text("\(Int(notificationVolume * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            Section {
                Defaults.Toggle(key: .watchAllAppsForNotifications) {
                    Text("Show notifications from all apps")
                }
            } header: {
                Text("Advanced")
            } footer: {
                Text("Notifications from all apps are mirrored in the notch by default. Disable to limit watching to the apps above.")
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func appRow(_ source: NotificationAppSource) -> some View {
        HStack {
            if let icon = source.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .cornerRadius(6)
            } else {
                Image(systemName: "bell")
                    .frame(width: 24, height: 24)
            }

            Toggle(source.displayName, isOn: Binding(
                get: { enabledNotificationApps.contains(source.rawValue) },
                set: { enabled in
                    var set = enabledNotificationApps
                    if enabled { set.insert(source.rawValue) }
                    else       { set.remove(source.rawValue) }
                    enabledNotificationApps = set
                }
            ))

            Spacer()

            if enabledNotificationApps.contains(source.rawValue) {
                Stepper(
                    value: Binding(
                        get: { displayDurations[source.rawValue] ?? 5.0 },
                        set: { displayDurations[source.rawValue] = $0 }
                    ),
                    in: 2...15, step: 1
                ) {
                    Text("\(Int(displayDurations[source.rawValue] ?? 5.0))s")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .controlSize(.small)
            }
        }
    }
}
