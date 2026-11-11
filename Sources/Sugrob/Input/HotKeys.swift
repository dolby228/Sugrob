import AppKit
import Carbon.HIToolbox
import os

private let log = Logger(subsystem: "dev.sugrob", category: "input")

/// Global hotkeys through Carbon `RegisterEventHotKey`. Unlike a keyboard event monitor,
/// this needs no Accessibility or Input Monitoring permission.
@MainActor
final class HotKeys {
    enum Action: UInt32, CaseIterable, Sendable {
        case togglePause = 1
        case openSettings
        case clearAll
        case quit

        var keyCode: UInt32 {
            switch self {
            case .togglePause: return UInt32(kVK_ANSI_S)
            case .openSettings: return UInt32(kVK_ANSI_Comma)
            case .clearAll: return UInt32(kVK_ANSI_K)
            case .quit: return UInt32(kVK_ANSI_Q)
            }
        }

        /// All hotkeys use ⌃⌥⌘: a combo apps rarely bind, so we do not steal theirs.
        static let modifiers = UInt32(cmdKey | optionKey | controlKey)

        var shortcut: String {
            switch self {
            case .togglePause: return "⌃⌥⌘S"
            case .openSettings: return "⌃⌥⌘,"
            case .clearAll: return "⌃⌥⌘K"
            case .quit: return "⌃⌥⌘Q"
            }
        }

        var title: String {
            switch self {
            case .togglePause: return "пауза / продолжить"
            case .openSettings: return "настройки"
            case .clearAll: return "очистить сугробы"
            case .quit: return "выйти из Sugrob"
            }
        }
    }

    /// Four-char code «SGRB».
    private static let signature: OSType = 0x5347_5242

    private let handler: @MainActor (Action) -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    init(handler: @escaping @MainActor (Action) -> Void) {
        self.handler = handler
    }

    func register() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let rawID = hotKeyID.id
                let hotKeys = Unmanaged<HotKeys>.fromOpaque(userData).takeUnretainedValue()
                // Carbon delivers application-target events on the main thread.
                MainActor.assumeIsolated {
                    hotKeys.fire(rawID)
                }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            log.warning("hotkey handler install failed: \(installStatus)")
            eventHandler = nil
            return
        }

        for action in Action.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: action.rawValue)
            let status = RegisterEventHotKey(
                action.keyCode,
                Action.modifiers,
                id,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
                log.debug("registered hotkey \(action.shortcut, privacy: .public)")
            } else {
                log.warning("hotkey \(action.shortcut, privacy: .public) registration failed: \(status), probably taken by another app")
            }
        }
    }

    func unregister() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private func fire(_ rawID: UInt32) {
        guard let action = Action(rawValue: rawID) else { return }
        log.debug("hotkey \(action.shortcut, privacy: .public)")
        handler(action)
    }
}
