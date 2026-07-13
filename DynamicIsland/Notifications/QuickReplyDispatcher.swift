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
import Foundation

/// Routes a quick-reply to the correct mechanism for the originating app.
///
/// Strategy, in order of preference:
///   1. Press the banner's native Reply action via AX — works for any app
///      that exposes a `UNNotificationAction` reply on its banner, because
///      the action is owned and dispatched by the source app itself.
///   2. AppleScript — only iMessage exposes a real send dictionary.
///   3. URL scheme — drops the user into the app at the right chat, but
///      doesn't actually send the message (best we can offer for WhatsApp /
///      Telegram / Slack / Discord without their cooperation).
enum QuickReplyDispatcher {

    static func send(reply: String, for notification: AtollNotification) {
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Always try AX-triggered native reply first. Most messaging apps
        // ship a reply text-field action on their notification banners; we
        // can drive it from AX since we already have permission.
        if let banner = notification.axBannerRef,
           tryAXReply(window: banner, text: trimmed) {
            return
        }

        switch notification.source {
        case .iMessage:
            replyViaMessages(to: notification.senderName, text: trimmed)
        case .whatsApp:
            openURLScheme("whatsapp://send?text=", text: trimmed)
        case .telegram:
            openURLScheme("tg://msg?text=", text: trimmed)
        case .slack:
            openApp(bundleID: notification.bundleID)
        case .discord:
            openApp(bundleID: notification.bundleID)
        default:
            openApp(bundleID: notification.bundleID)
        }
    }

    // MARK: - AX native reply

    /// Walks the banner subtree for a text field + a Reply / Send button.
    /// Sets the field's value to `text` and performs `AXPress` on the
    /// matching button. Returns false if either piece isn't found.
    private static func tryAXReply(window: AXUIElement, text: String) -> Bool {
        let (textField, sendButton) = findReplyControls(in: window)
        guard let textField, let sendButton else { return false }

        // Setting the value triggers the field's `set` AX action, which the
        // source app processes as if the user had typed it.
        let valueStatus = AXUIElementSetAttributeValue(
            textField,
            kAXValueAttribute as CFString,
            text as CFTypeRef
        )
        guard valueStatus == .success else { return false }

        let pressStatus = AXUIElementPerformAction(sendButton, kAXPressAction as CFString)
        return pressStatus == .success
    }

    private static func findReplyControls(in window: AXUIElement) -> (AXUIElement?, AXUIElement?) {
        var textField: AXUIElement?
        var sendButton: AXUIElement?

        var queue: [AXUIElement] = [window]
        var visited = 0
        while !queue.isEmpty, visited < 128 {
            let element = queue.removeFirst()
            visited += 1

            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String

            if textField == nil, role == kAXTextFieldRole || role == kAXTextAreaRole {
                textField = element
            }

            if sendButton == nil, role == kAXButtonRole {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &titleRef)
                let title = (titleRef as? String) ?? ""
                let lower = title.lowercased()
                if lower == "send" || lower == "reply" || lower.contains("send") {
                    sendButton = element
                }
            }

            if textField != nil, sendButton != nil {
                break
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let nested = children as? [AXUIElement] {
                queue.append(contentsOf: nested)
            }
        }

        return (textField, sendButton)
    }

    // MARK: - iMessage via AppleScript

    private static func replyViaMessages(to recipient: String, text: String) {
        let safeRecipient = recipient.replacingOccurrences(of: "\"", with: "\\\"")
        let safeText = text.replacingOccurrences(of: "\"", with: "\\\"")

        let script = """
        tell application "Messages"
            try
                set targetService to 1st service whose service type = iMessage
                set targetBuddy to buddy "\(safeRecipient)" of targetService
                send "\(safeText)" to targetBuddy
            on error
                -- Fall through: caller will see Messages.app open with no reply sent.
            end try
        end tell
        """
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&error)
        }
    }

    // MARK: - Fallbacks

    private static func openURLScheme(_ prefix: String, text: String) {
        let encoded = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: prefix + encoded) else { return }
        NSWorkspace.shared.open(url)
    }

    private static func openApp(bundleID: String) {
        guard !bundleID.isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
    }
}
