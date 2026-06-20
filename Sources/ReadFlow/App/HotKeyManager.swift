//
//  HotKeyManager.swift
//  ReadFlow
//
//  Registers the global hotkey Option-R via Carbon `RegisterEventHotKey` and
//  posts `.readFlowReadSelection` when fired. Unregisters cleanly on deinit.
//  No retain cycles in the Carbon callback (the callback posts a Notification —
//  it never captures `self`).
//

import AppKit
import Carbon.HIToolbox

/// Owns a single global hotkey (Option-R) and turns it into a
/// `.readFlowReadSelection` notification. Carbon hotkeys are process-global and
/// do NOT require Accessibility permission, so the hotkey works even before the
/// user has granted AX (the subsequent text capture is what needs AX).
final class HotKeyManager {

    // A unique signature/id so we can identify our own hotkey events.
    private static let hotKeySignature: OSType = {
        // 'RFlw' as a four-char code.
        let chars = "RFlw".utf8
        return chars.reduce(OSType(0)) { ($0 << 8) + OSType($1) }
    }()
    private static let hotKeyID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isRegistered = false

    init() {}

    deinit {
        // deinit may run off the main thread in theory; Carbon teardown is
        // thread-safe enough for unregister and we touch no UI here.
        unregister()
    }

    /// Register Option-R as the global read hotkey. Idempotent: calling twice
    /// without an intervening `unregister()` is a no-op.
    func register() {
        guard !isRegistered else { return }

        // 1) Install the application-level event handler for hotkey-pressed.
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))

        let handler: EventHandlerUPP = { _, eventRef, _ -> OSStatus in
            guard let eventRef = eventRef else { return OSStatus(eventNotHandledErr) }

            var firedID = EventHotKeyID()
            let status = GetEventParameter(eventRef,
                                           EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID),
                                           nil,
                                           MemoryLayout<EventHotKeyID>.size,
                                           nil,
                                           &firedID)
            guard status == noErr else { return status }

            // Only react to OUR hotkey.
            if firedID.signature == HotKeyManager.hotKeySignature,
               firedID.id == HotKeyManager.hotKeyID {
                // Post on the main thread — UI/capture happens downstream.
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .readFlowReadSelection, object: nil)
                }
                return noErr
            }
            return OSStatus(eventNotHandledErr)
        }

        var handlerRef: EventHandlerRef?
        let installStatus = InstallEventHandler(GetApplicationEventTarget(),
                                                handler,
                                                1,
                                                &eventType,
                                                nil,            // no userData → no retain cycle
                                                &handlerRef)
        guard installStatus == noErr else {
            NSLog("ReadFlow: failed to install hotkey event handler (status \(installStatus))")
            return
        }
        eventHandlerRef = handlerRef

        // 2) Register Option-R itself.
        let hotKeyID = EventHotKeyID(signature: HotKeyManager.hotKeySignature,
                                     id: HotKeyManager.hotKeyID)
        var ref: EventHotKeyRef?
        let registerStatus = RegisterEventHotKey(UInt32(kVK_ANSI_R),
                                                 UInt32(optionKey),
                                                 hotKeyID,
                                                 GetApplicationEventTarget(),
                                                 0,
                                                 &ref)
        guard registerStatus == noErr, let ref = ref else {
            NSLog("ReadFlow: failed to register Option-R hotkey (status \(registerStatus))")
            // Tear down the handler we installed so we don't leak it.
            if let handlerRef = eventHandlerRef {
                RemoveEventHandler(handlerRef)
                eventHandlerRef = nil
            }
            return
        }
        hotKeyRef = ref
        isRegistered = true
    }

    /// Unregister the hotkey and remove the event handler. Safe to call when
    /// nothing is registered.
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }
        isRegistered = false
    }
}
