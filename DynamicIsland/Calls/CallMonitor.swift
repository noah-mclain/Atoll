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

/// Surfaces incoming calls through Atoll's notch.
///
/// Detection path: every call notification on macOS — FaceTime, iPhone via
/// Continuity, Discord, WhatsApp, etc. — first appears as a `usernoted`
/// banner. We piggy-back on `NotificationObserver`, recognize the
/// call-shaped ones (title/body says "Incoming call", "is calling", or
/// "FaceTime…"), and republish them as `AtollCall` instead of letting
/// them flow through to the notification feed.
///
/// CallKit on macOS only exposes `CXProvider` for VoIP apps reporting their
/// own calls — `CXCallObserver` is iOS-only — so there is no programmatic
/// way for a bystander app to answer FaceTime or Continuity. "Accept" here
/// opens the source app; "Decline" just dismisses Atoll's pill (and lets
/// the call ring out in the underlying app).
@MainActor
final class CallMonitor: NSObject, ObservableObject {

    static let shared = CallMonitor()

    @Published private(set) var activeCall: AtollCall?
    @Published private(set) var callState: CallState = .idle

    enum CallState: Equatable {
        case idle
        case ringing(AtollCall)
    }

    private var ringtonePlayer: RingtonePlayer?
    private var autoDeclineTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private override init() {
        super.init()
        observeNotificationBanners()
    }

    // MARK: - Public API

    func acceptCall(_ call: AtollCall) {
        ringtonePlayer?.stop()
        switch call.source {
        case .facetime:
            openApp(bundleID: "com.apple.FaceTime")
        case .phone:
            openApp(bundleID: "com.apple.FaceTime")
        case .discord:
            openApp(bundleID: "com.hnc.Discord")
        case .voip(let bundleID, _, _, _):
            openApp(bundleID: bundleID)
        }
        dismissCall()
    }

    func declineCall(_ call: AtollCall) {
        ringtonePlayer?.stop()
        // We can't programmatically decline a system call from a bystander
        // app; dismissing the pill just hides our overlay. The underlying
        // ringtone keeps playing in FaceTime / Discord / whatever until it
        // times out naturally, unless the user interacts there.
        dismissCall()
    }

    func dismissCall() {
        ringtonePlayer?.stop()
        ringtonePlayer = nil
        autoDeclineTimer?.invalidate()
        autoDeclineTimer = nil
        activeCall = nil
        callState = .idle
        NotificationObserver.tryExitCommunicationMode()
    }

    // MARK: - Banner-based call detection

    private func observeNotificationBanners() {
        NotificationObserver.shared.$latestNotification
            .compactMap { $0 }
            .sink { [weak self] notification in
                guard let self else { return }
                // The "missed call" / "call ended" follow-up is the reliable
                // signal that ringing stopped in the source app — kill our
                // ringtone instead of letting it play on. The notification
                // itself stays in the feed as a normal banner.
                if case .ringing = self.callState, Self.indicatesCallEnded(notification) {
                    self.dismissCall()
                    return
                }
                if let call = Self.callFromBanner(notification) {
                    NotificationObserver.shared.dismiss(notification)
                    self.presentCall(call)
                }
            }
            .store(in: &cancellables)
    }

    /// True when the banner reads like the end of a call attempt (missed,
    /// declined elsewhere, or hung up) rather than a new incoming ring.
    private static func indicatesCallEnded(_ notification: AtollNotification) -> Bool {
        let text = "\(notification.senderName) \(notification.body)".lowercased()
        return text.contains("missed")
            || text.contains("call ended")
            || text.contains("declined")
            || text.contains("cancelled call")
            || text.contains("canceled call")
    }

    /// Returns an AtollCall if the banner reads like an incoming call.
    /// Heuristic match against the title + body; tuned for FaceTime,
    /// Discord, and WhatsApp Calls — extend as needed.
    private static func callFromBanner(_ notification: AtollNotification) -> AtollCall? {
        let bodyLower = notification.body.lowercased()
        let senderLower = notification.senderName.lowercased()
        let isCallShaped =
            bodyLower.contains("incoming call")
            || bodyLower.contains("incoming voice call")
            || bodyLower.contains("incoming video call")
            || bodyLower.contains("is calling")
            || bodyLower.contains("calling…")
            || bodyLower.contains("calling...")
            || bodyLower.contains("would like to facetime")
            // FaceTime banners are effectively always a live call, except the
            // "missed call" follow-up, which stays a normal notification.
            || (notification.source == .facetime && !bodyLower.contains("missed"))

        guard isCallShaped else { return nil }

        let source: CallSource
        switch notification.source {
        case .facetime:
            let isVideo = bodyLower.contains("video") || senderLower.contains("video")
            source = .facetime(
                callerName: notification.senderName,
                callerImage: notification.senderAvatarImage,
                isVideo: isVideo
            )
        case .discord:
            source = .discord(
                callerName: notification.senderName,
                callerImage: notification.senderAvatarImage,
                channelName: notification.subtitle ?? "Voice Channel",
                guildName: nil
            )
        case .iMessage where senderLower.contains("phone") || bodyLower.contains("iphone"):
            source = .phone(
                callerName: notification.senderName,
                callerImage: notification.senderAvatarImage,
                phoneNumber: ""
            )
        default:
            source = .voip(
                appBundleID: notification.bundleID,
                appName: notification.source.displayName,
                callerName: notification.senderName,
                callerImage: notification.senderAvatarImage
            )
        }

        return AtollCall(source: source, startedAt: Date(), callUUID: nil)
    }

    // MARK: - Internal

    private func presentCall(_ call: AtollCall) {
        guard CallSettings.shared.isEnabled(for: call.source.sourceCategory) else { return }

        activeCall = call
        callState = .ringing(call)
        NotificationObserver.enterCommunicationMode()

        let player = RingtonePlayer()
        player.play(for: call.source)
        ringtonePlayer = player

        let timeout = CallSettings.shared.autoDeclineAfterSeconds
        autoDeclineTimer?.invalidate()
        autoDeclineTimer = nil
        if timeout > 0 {
            let pendingCallID = call.id
            autoDeclineTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(timeout), repeats: false) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if case .ringing(let active) = self.callState, active.id == pendingCallID {
                        self.declineCall(active)
                    }
                }
            }
        }
    }

    private func openApp(bundleID: String) {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
