import AppKit
import Carbon.HIToolbox

/// Carbon event hotkeys work globally without Accessibility or input-monitoring access.
@MainActor
final class GlobalHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private let action: () -> Void
    private static let signature: OSType = 0x437A4E74 // CzNt

    enum RegistrationError: LocalizedError {
        case eventHandler(OSStatus)
        case hotKey(OSStatus)

        var errorDescription: String? {
            switch self {
            case .eventHandler(let status):
                return "Could not install the global capture shortcut handler (OSStatus \(status))."
            case .hotKey(let status):
                return "Could not register Command–Shift–Space (OSStatus \(status)). Another application or system shortcut may already use it. Capture remains available from Cozy Notes."
            }
        }
    }

    init(action: @escaping () -> Void) throws {
        self.action = action
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, identifier.signature == 0x437A4E74, identifier.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            // Application event-target handlers are delivered by the main event loop.
            MainActor.assumeIsolated {
                Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().action()
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installStatus == noErr else { throw RegistrationError.eventHandler(installStatus) }

        let identifier = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(UInt32(kVK_Space), UInt32(cmdKey | shiftKey), identifier,
                                                GetApplicationEventTarget(), 0, &hotKey)
        guard registerStatus == noErr else {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            throw RegistrationError.hotKey(registerStatus)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
