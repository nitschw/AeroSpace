@MainActor var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // A command's grant is in flight: the only native focus change that
        // counts is that grant landing. Everything else — abandoned grants
        // from earlier hops, the still-active app reasserting itself — is
        // transition noise; following it dragged rapid switchers to
        // whatever workspace their frontmost app's window lived on. Noise
        // is left unrecorded so this re-evaluates on the next refresh, and
        // a grant no app delivered within 3 seconds stops gating.
        if let grant = inFlightGrant, grant.at >= lastSetFocusAt {
            if nativeFocused?.windowId == grant.windowId {
                inFlightGrant = nil  // landed; fall through and confirm it
            } else if grant.at.distance(to: .now) < 3.0 {
                return
            } else {
                inFlightGrant = nil  // never landed; resume normal following
            }
        }
        // A grant the engine itself issued, landing after the user's latest
        // focus command, is the echo of an abandoned switch — a slow app
        // delivering yesterday's instruction — never the user's intent.
        // Genuine user clicks were never granted by us and follow instantly.
        if let native = nativeFocused,
           let granted = engineFocusGrants[native.windowId],
           granted < lastSetFocusAt
        {
            lastKnownNativeFocusedWindowId = native.windowId
            return
        }
        // The user just focused an empty workspace; a native focus "change"
        // arriving right after is the old window reasserting (no window on
        // an empty workspace took focus away from it), not the user leaving.
        if focus.windowOrNil == nil,
           nativeFocused != nil,
           focusedEmptyWorkspaceAt.distance(to: .now) < 1.0
        {
            lastKnownNativeFocusedWindowId = nativeFocused?.windowId
            return
        }
        _ = nativeFocused?.focusWindow()
        lastKnownNativeFocusedWindowId = nativeFocused?.windowId
    }
    nativeFocused?.macAppUnsafe.lastNativeFocusedWindowId = nativeFocused?.windowId
}
