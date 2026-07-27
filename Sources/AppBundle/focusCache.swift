@MainActor private var lastKnownNativeFocusedWindowId: UInt32? = nil

/// The data should flow (from nativeFocused to focused) and
///                      (from nativeFocused to lastKnownNativeFocusedWindowId)
/// Alternative names: takeFocusFromMacOs, syncFocusFromMacOs
@MainActor func updateFocusCache(_ nativeFocused: Window?) {
    if nativeFocused?.parent is MacosPopupWindowsContainer {
        return
    }
    if nativeFocused?.windowId != lastKnownNativeFocusedWindowId {
        // The user just focused an empty workspace; a native focus "change"
        // arriving right after is a stale async grant from the previous
        // switch (or the old window reasserting), not the user leaving.
        // Swallow it — record it as seen so genuine later changes register,
        // but don't follow it off the workspace they chose.
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
