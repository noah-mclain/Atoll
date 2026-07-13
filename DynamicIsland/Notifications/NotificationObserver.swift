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
import ApplicationServices
import Combine
import Darwin
import Foundation

/// Debug-build console output, tagged for filtering. Search Xcode's debug
/// console for "[AtollNotif]".
private func atollNotifLog(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[AtollNotif] \(message())")
    #endif
}

/// Observes system notification banners by attaching `AXObserver` instances to
/// every process that might host banner windows on the current macOS version:
///
///   * `usernoted`             — delivery daemon, owns banners on macOS ≤ 13
///   * `usernotificationsd`    — modern delivery daemon on macOS 14+
///   * `NotificationCenter`    — the renderer process on macOS 14+
///   * `notificationcenterui`  — alternate name for the same renderer
///
/// We try them all. Whichever process actually owns the banner window fires
/// the AX event; the others sit idle. A periodic 1 s poll provides a fallback
/// for the cases where AX events don't fire (some banner styles, focused
/// app windows, etc.). All discovery is logged so it's easy to see what's
/// happening in the Xcode console — search for "AtollNotif" to filter.
@MainActor
final class NotificationObserver: NSObject, ObservableObject {

    static let shared = NotificationObserver()

    @Published private(set) var pendingNotifications: [AtollNotification] = []
    @Published private(set) var latestNotification: AtollNotification?
    @Published private(set) var isInstalled: Bool = false

    /// The process names we'll try to attach to. Order matters only for
    /// logging; we install on all that resolve.
    private static let candidateProcessNames: [String] = [
        "usernoted",
        "usernotificationsd",
        "NotificationCenter",
        "notificationcenterui",
    ]

    private struct AttachedProcess {
        let pid: pid_t
        let name: String
        let appElement: AXUIElement
        let observer: AXObserver
    }

    private var attached: [pid_t: AttachedProcess] = [:]
    private var seenWindowSignatures: Set<String> = []
    private var dismissTimers: [UUID: Timer] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var pollTimer: Timer?

    private static var savedPreviousView: NotchViews?

    private override init() {
        super.init()
        atollNotifLog("NotificationObserver init — singleton constructed.")
        observeAppLifecycle()
        observeAccessibilityPermission()
        Task { @MainActor in
            self.tryInstall()
        }
    }

    private func observeAccessibilityPermission() {
        AccessibilityPermissionStore.shared.$isAuthorized
            .removeDuplicates()
            .sink { [weak self] authorized in
                guard let self else { return }
                if authorized {
                    Task { @MainActor in self.tryInstall() }
                } else {
                    Task { @MainActor in self.teardown() }
                }
            }
            .store(in: &cancellables)
    }

    deinit {
        if let pollTimer { pollTimer.invalidate() }
    }

    // MARK: - Workspace lifecycle

    private func observeAppLifecycle() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidLaunchApp(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceDidTerminateApp(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
    }

    @objc private func workspaceDidLaunchApp(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let name = app.localizedName ?? app.executableURL?.lastPathComponent,
            Self.candidateProcessNames.contains(where: { name.caseInsensitiveCompare($0) == .orderedSame })
        else { return }
        Task { @MainActor in self.tryInstall() }
    }

    @objc private func workspaceDidTerminateApp(_ note: Notification) {
        guard
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let name = app.localizedName ?? app.executableURL?.lastPathComponent,
            Self.candidateProcessNames.contains(where: { name.caseInsensitiveCompare($0) == .orderedSame })
        else { return }
        Task { @MainActor in self.detach(pid: app.processIdentifier) }
    }

    // MARK: - Install AX observers

    func tryInstall() {
        let authorized = AccessibilityPermissionStore.shared.isAuthorized
        atollNotifLog("tryInstall called. AX authorized = \(authorized).")
        guard authorized else {
            atollNotifLog("AX permission not yet granted; deferring install.")
            return
        }

        let pids = Self.findCandidatePIDs()
        atollNotifLog("Candidate banner processes found: \(pids.map { "\($0.1)(pid=\($0.0))" }.joined(separator: ", "))")
        if pids.isEmpty {
            atollNotifLog("No candidate banner processes found. Retrying in 3s.")
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.tryInstall()
            }
            return
        }

        for (pid, name) in pids where attached[pid] == nil {
            install(pid: pid, name: name)
        }

        startPollTimer()
        isInstalled = !attached.isEmpty
        atollNotifLog("tryInstall finished. Attached to \(attached.count) process(es). Poll timer running.")
    }

    private func install(pid: pid_t, name: String) {
        let appElement = AXUIElementCreateApplication(pid)
        var observer: AXObserver?
        let status = AXObserverCreate(pid, axNotificationCallback, &observer)
        guard status == .success, let observer else {
            atollNotifLog("AXObserverCreate FAILED for \(name) (pid \(pid)): AXError=\(status.rawValue). " +
                          "This usually means macOS denied AX observation of that process.")
            return
        }

        let context = Unmanaged.passUnretained(self).toOpaque()
        let names: [String] = [
            kAXWindowCreatedNotification as String,
            kAXCreatedNotification as String,
            kAXMainWindowChangedNotification as String,
        ]
        for n in names {
            let addStatus = AXObserverAddNotification(observer, appElement, n as CFString, context)
            if addStatus != .success {
                atollNotifLog("AXObserverAddNotification(\(n)) on \(name) returned \(addStatus.rawValue).")
            }
        }

        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        attached[pid] = AttachedProcess(pid: pid, name: name, appElement: appElement, observer: observer)
        atollNotifLog("Attached AX observer to \(name) (pid \(pid)).")

        scanWindows(of: appElement, source: "initial scan: \(name)")
    }

    private func detach(pid: pid_t) {
        guard let entry = attached.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(entry.observer),
            .defaultMode
        )
        atollNotifLog("Detached AX observer from \(entry.name) (pid \(pid)).")
        isInstalled = !attached.isEmpty
        if attached.isEmpty {
            stopPollTimer()
        }
    }

    private func teardown() {
        for pid in attached.keys {
            detach(pid: pid)
        }
        stopPollTimer()
        isInstalled = false
    }

    // MARK: - Poll fallback

    private func startPollTimer() {
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAttachedWindows() }
        }
    }

    private func stopPollTimer() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollAttachedWindows() {
        for entry in attached.values {
            scanWindows(of: entry.appElement, source: "poll: \(entry.name)")
        }
    }

    // MARK: - AX event handling

    fileprivate func handleAXEvent(element: AXUIElement, notification: String, pid: pid_t) {
        let window = Self.enclosingWindow(of: element) ?? element
        atollNotifLog("AX event \(notification) from pid \(pid)")
        process(window: window, source: "event: \(notification)")
    }

    private func scanWindows(of appElement: AXUIElement, source: String) {
        var windowsRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXWindowsAttribute as CFString,
            &windowsRef
        )
        guard status == .success else {
            if !source.hasPrefix("poll:") {
                atollNotifLog("AXUIElementCopyAttributeValue(windows) on \(source) returned \(status.rawValue).")
            }
            return
        }
        guard let windows = windowsRef as? [AXUIElement] else { return }
        for window in windows {
            process(window: window, source: source)
        }
    }

    private func process(window: AXUIElement, source: String) {
        guard let signature = Self.signatureFor(window: window) else { return }
        guard !seenWindowSignatures.contains(signature) else { return }
        seenWindowSignatures.insert(signature)
        if seenWindowSignatures.count > 512 {
            seenWindowSignatures.removeAll(keepingCapacity: true)
        }

        atollNotifLog("NEW BANNER from \(source):\n    \(signature)")

        if let notification = NotificationParser.parse(window: window) {
            receive(notification)
        } else {
            atollNotifLog("Parser returned nil for window; treating as non-banner.")
        }
    }

    // MARK: - Receive + queue management

    func receive(_ notification: AtollNotification) {
        guard NotificationSettings.shared.isEnabled(for: notification.source) else {
            atollNotifLog("Notification from \(notification.source.displayName) filtered by settings — skipping.")
            return
        }
        atollNotifLog("Notification ACCEPTED: \(notification.source.displayName) — \(notification.senderName): \(notification.body)")

        SoundPlayer.shared.playNotificationSound(for: notification.source)

        pendingNotifications.append(notification)
        latestNotification = notification
        Self.enterCommunicationMode()

        let duration = NotificationSettings.shared.displayDuration(for: notification.source)
        let timer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.dismiss(id: notification.id)
            }
        }
        dismissTimers[notification.id] = timer
    }

    func dismiss(_ notification: AtollNotification) {
        dismiss(id: notification.id)
    }

    private func dismiss(id: UUID) {
        dismissTimers[id]?.invalidate()
        dismissTimers.removeValue(forKey: id)
        pendingNotifications.removeAll { $0.id == id }
        if latestNotification?.id == id {
            latestNotification = pendingNotifications.last
        }
        Self.tryExitCommunicationMode()
    }

    // MARK: - Communication-mode coordination

    static func enterCommunicationMode() {
        let coordinator = DynamicIslandViewCoordinator.shared
        if coordinator.currentView != .communication {
            savedPreviousView = coordinator.currentView
            coordinator.currentView = .communication
        }
        AppDelegate.shared?.vm.open()
    }

    static func tryExitCommunicationMode() {
        let hasNotification = NotificationObserver.shared.latestNotification != nil
        let hasRingingCall: Bool
        if case .ringing = CallMonitor.shared.callState { hasRingingCall = true }
        else                                            { hasRingingCall = false }
        guard !hasNotification && !hasRingingCall else { return }

        let coordinator = DynamicIslandViewCoordinator.shared
        if coordinator.currentView == .communication {
            coordinator.currentView = savedPreviousView ?? .home
        }
        savedPreviousView = nil
        AppDelegate.shared?.vm.close()
    }

    // MARK: - PID discovery

    private static func findCandidatePIDs() -> [(pid_t, String)] {
        var results: [(pid_t, String)] = []
        let lowered = candidateProcessNames.map { $0.lowercased() }

        // 1. NSWorkspace catches GUI apps (NotificationCenter).
        for app in NSWorkspace.shared.runningApplications {
            let name = (app.localizedName ?? app.executableURL?.lastPathComponent ?? "").lowercased()
            if lowered.contains(where: { name == $0 || name.contains($0) }) {
                results.append((app.processIdentifier, name))
            }
        }

        // 2. proc_listallpids catches background daemons (usernoted /
        //    usernotificationsd) that NSWorkspace skips.
        let maxPIDs: Int32 = 4096
        let bufferSize = Int(maxPIDs) * MemoryLayout<pid_t>.size
        let buffer = UnsafeMutablePointer<pid_t>.allocate(capacity: Int(maxPIDs))
        defer { buffer.deallocate() }

        let bytes = proc_listallpids(buffer, Int32(bufferSize))
        if bytes > 0 {
            let count = Int(bytes) / MemoryLayout<pid_t>.size
            let nameBufferSize = Int(MAXPATHLEN)
            let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: nameBufferSize)
            defer { nameBuffer.deallocate() }

            for i in 0..<count {
                let pid = buffer[i]
                guard pid > 0 else { continue }
                if results.contains(where: { $0.0 == pid }) { continue }
                let written = proc_name(pid, nameBuffer, UInt32(nameBufferSize))
                guard written > 0 else { continue }
                let name = String(cString: nameBuffer).lowercased()
                if lowered.contains(where: { name == $0 }) {
                    results.append((pid, name))
                }
            }
        }

        return results
    }

    // MARK: - AX helpers

    private static func enclosingWindow(of element: AXUIElement) -> AXUIElement? {
        var current: AXUIElement = element
        for _ in 0..<8 {
            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String,
               role == kAXWindowRole {
                return current
            }
            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
               let parent = parentRef {
                current = parent as! AXUIElement
            } else {
                break
            }
        }
        return nil
    }

    private static func signatureFor(window: AXUIElement) -> String? {
        var collected: [String] = []
        collectStrings(from: window, into: &collected, depth: 0, limit: 32)
        guard !collected.isEmpty else { return nil }
        return collected.joined(separator: "│")
    }

    nonisolated static func collectStrings(
        from element: AXUIElement,
        into bucket: inout [String],
        depth: Int,
        limit: Int
    ) {
        guard depth < 6 else { return }
        guard bucket.count < limit else { return }

        for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
            var ref: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
               let str = ref as? String,
               !str.isEmpty {
                bucket.append(str)
            }
        }

        var childrenRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
           let children = childrenRef as? [AXUIElement] {
            for child in children {
                collectStrings(from: child, into: &bucket, depth: depth + 1, limit: limit)
            }
        }
    }
}

// MARK: - AX callback bridge

private func axNotificationCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ userData: UnsafeMutableRawPointer?
) {
    guard let userData else { return }
    let bridge = Unmanaged<NotificationObserver>.fromOpaque(userData).takeUnretainedValue()
    let notificationName = notification as String
    // PID lookup from the element is not exposed in public AX; we pass 0 and
    // rely on the call back's identity for context. The actual pid is logged
    // by the polling path; for events we just log the notification name.
    DispatchQueue.main.async {
        Task { @MainActor in
            bridge.handleAXEvent(element: element, notification: notificationName, pid: 0)
        }
    }
}
