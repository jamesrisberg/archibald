import AppKit
import Carbon

final class GlobalHotKeyManager {
    private var primaryHotKey: EventHotKeyRef?
    private var hideHotKey: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var isRunning = false

    private var primaryKeyCode: UInt32 = UInt32(kVK_ANSI_Backslash)
    private var primaryModifiers: UInt32 = UInt32(optionKey)

    var onPrimary: (() -> Void)?
    var onHide: (() -> Void)?

    func start() {
        stop()
        installHandler()

        register(
            hotKey: &primaryHotKey,
            keyCode: primaryKeyCode,
            modifiers: primaryModifiers,
            id: 1
        )
        register(
            hotKey: &hideHotKey,
            keyCode: UInt32(kVK_ANSI_Backslash),
            modifiers: UInt32(cmdKey | optionKey),
            id: 2
        )
        isRunning = true
    }

    func stop() {
        if let primaryHotKey {
            UnregisterEventHotKey(primaryHotKey)
            self.primaryHotKey = nil
        }
        if let hideHotKey {
            UnregisterEventHotKey(hideHotKey)
            self.hideHotKey = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        isRunning = false
    }

    func updatePrimaryHotKey(_ option: AppSettings.HotKeyOption) {
        let (keyCode, modifiers) = mapPrimaryHotKey(option)
        primaryKeyCode = keyCode
        primaryModifiers = modifiers
        if isRunning {
            start()
        }
    }

    private func register(hotKey: inout EventHotKeyRef?, keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(bitPattern: 0x41524348), id: id) // "ARCH"
        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
    }

    private func installHandler() {
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event else { return noErr }
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
                guard status == noErr,
                      let manager = Unmanaged<GlobalHotKeyManager>.fromOpaque(userData!).takeUnretainedValue() as GlobalHotKeyManager? else {
                    return noErr
                }
                DispatchQueue.main.async {
                    switch hotKeyID.id {
                    case 1:
                        manager.onPrimary?()
                    case 2:
                        manager.onHide?()
                    default:
                        break
                    }
                }
                return noErr
            },
            1,
            &eventSpec,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
    }

    private func mapPrimaryHotKey(_ option: AppSettings.HotKeyOption) -> (UInt32, UInt32) {
        switch option {
        case .optionBackslash:
            return (UInt32(kVK_ANSI_Backslash), UInt32(optionKey))
        case .shiftBackslash:
            return (UInt32(kVK_ANSI_Backslash), UInt32(shiftKey))
        case .optionSpace:
            return (UInt32(kVK_Space), UInt32(optionKey))
        case .controlSpace:
            return (UInt32(kVK_Space), UInt32(controlKey))
        case .commandShiftSpace:
            return (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        }
    }
}
