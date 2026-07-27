import AppKit
import Common

enum EffectiveLeaf {
    case window(Window)
    case emptyWorkspace(Workspace)
}
extension LiveFocus {
    var asLeaf: EffectiveLeaf {
        if let windowOrNil { .window(windowOrNil) } else { .emptyWorkspace(workspace) }
    }
}

/// This object should be only passed around but never memorized
/// Alternative name: ResolvedFocus
struct LiveFocus: AeroAny, Equatable {
    let windowOrNil: Window?
    var workspace: Workspace

    @MainActor fileprivate var frozen: FrozenFocus {
        return FrozenFocus(
            windowId: windowOrNil?.windowId,
            workspaceName: workspace.name,
            monitorId_oneBased: workspace.workspaceMonitor.monitorId_oneBased ?? 0,
        )
    }
}

/// "old", "captured", "frozen in time" Focus
/// It's safe to keep a hard reference to this object.
/// Unlike in LiveFocus, information inside FrozenFocus isn't guaranteed to be self-consistent.
/// window - workspace - monitor relation could change since the moment object was created
private struct FrozenFocus: AeroAny, Equatable, Sendable {
    let windowId: UInt32?
    let workspaceName: String
    // monitorId is not part of the focus. We keep it here only for 'on-focused-monitor-changed' to work
    let monitorId_oneBased: Int

    @MainActor var live: LiveFocus { // Important: don't access focus.monitorId here. monitorId is not part of the focus. Always prefer workspace
        let window: Window? = windowId.flatMap { Window.get(byId: $0) }
        let workspace = Workspace.get(byName: workspaceName)

        let workspaceFocus = workspace.toLiveFocus()
        let windowFocus = window?.toLiveFocusOrNil() ?? workspaceFocus

        return workspaceFocus.workspace != windowFocus.workspace
            ? workspaceFocus // If window and workspace become separated prefer workspace
            : windowFocus
    }
}

@MainActor private var _focus: FrozenFocus = {
    let monitor = mainMonitor
    return FrozenFocus(windowId: nil, workspaceName: monitor.activeWorkspace.name, monitorId_oneBased: monitor.monitorId_oneBased ?? 0)
}()

/// Global focus.
/// Commands must be cautious about accessing this property directly. There are legitimate cases.
/// But, in general, commands must firstly check --window-id, --workspace, AEROSPACE_WINDOW_ID env and
/// AEROSPACE_WORKSPACE env before accessing the global focus.
@MainActor var focus: LiveFocus { _focus.live }

/// When a command deliberately focused an *empty* workspace. An empty
/// workspace gives macOS nothing to focus, so the previously focused window
/// keeps native focus — and async focus grants queued by an earlier
/// workspace switch can land after this one. Both look like "the native
/// focused window changed" to the focus cache, which then follows them and
/// drags the user right back off the workspace they just chose. The cache
/// swallows such events for a beat after an empty-workspace focus.
@MainActor var focusedEmptyWorkspaceAt: Date = .distantPast

/// When any command last set focus, and every native-focus grant the engine
/// itself has issued (windowId → when). Together they let the focus cache
/// tell a *user* focusing a window from the engine's own async focus grants
/// landing late: a slow app can deliver the grant from a workspace command
/// seconds after the user has already moved on (endpoint security makes
/// everything slower), and following it dragged the user backwards through
/// their own switch history — clicking through workspaces 4, 5, 6 landed on
/// 4. A grant issued before the latest setFocus is an echo of an abandoned
/// command, never intent.
@MainActor var lastSetFocusAt: Date = .distantPast
@MainActor var engineFocusGrants: [UInt32: Date] = [:]
/// The grant currently in flight: the window the latest command asked macOS
/// to focus. Until it lands (or times out), other native focus changes are
/// transition noise — abandoned earlier grants, or the still-active app
/// reasserting itself — and following them is how rapid switching dragged
/// the user to whatever workspace their frontmost app's window lived on.
@MainActor var inFlightGrant: (windowId: UInt32, at: Date)? = nil

@MainActor func recordEngineFocusGrant(_ windowId: UInt32) {
    if engineFocusGrants.count > 64 { engineFocusGrants.removeAll() }
    engineFocusGrants[windowId] = .now
    // Granting focus to the window that already holds it produces no
    // confirmation event — gating on one would silence real changes for
    // the full timeout.
    inFlightGrant = windowId == lastKnownNativeFocusedWindowId ? nil : (windowId, .now)
}

@MainActor func setFocus(to newFocus: LiveFocus) -> Bool {
    if _focus == newFocus.frozen { return true }
    let oldFocus = focus
    // Normalize mruWindow when focus away from a workspace
    if oldFocus.workspace != newFocus.workspace {
        oldFocus.windowOrNil?.markAsMostRecentChild()
    }
    if newFocus.windowOrNil == nil {
        focusedEmptyWorkspaceAt = .now
    }

    _focus = newFocus.frozen
    lastSetFocusAt = .now
    let status = newFocus.workspace.workspaceMonitor.setActiveWorkspace(newFocus.workspace)

    newFocus.windowOrNil?.markAsMostRecentChild()
    return status
}
extension Window {
    @MainActor func focusWindow() -> Bool {
        if let focus = toLiveFocusOrNil() {
            return setFocus(to: focus)
        } else {
            // todo We should also exit-native-hidden/unminimize[/exit-native-fullscreen?] window if we want to fix ID-B6E178F2
            //      and retry to focus the window. Otherwise, it's not possible to focus minimized/hidden windows
            return false
        }
    }

    @MainActor func toLiveFocusOrNil() -> LiveFocus? { visualWorkspace.map { LiveFocus(windowOrNil: self, workspace: $0) } }
}
extension Workspace {
    @MainActor func focusWorkspace() -> Bool { setFocus(to: toLiveFocus()) }

    func toLiveFocus() -> LiveFocus {
        // todo unfortunately mostRecentWindowRecursive may recursively reach empty rootTilingContainer
        //      while floating or macos unconventional windows might be presented
        if let wd = mostRecentWindowRecursive ?? anyLeafWindowRecursive {
            LiveFocus(windowOrNil: wd, workspace: self)
        } else {
            LiveFocus(windowOrNil: nil, workspace: self) // emptyWorkspace
        }
    }
}

@MainActor private var _lastKnownFocus: FrozenFocus = _focus

// Used by workspace-back-and-forth
@MainActor var _prevFocusedWorkspaceName: String? = nil {
    didSet {
        prevFocusedWorkspaceDate = .now
    }
}
@MainActor var prevFocusedWorkspaceDate: Date = .distantPast
@MainActor var prevFocusedWorkspace: Workspace? { _prevFocusedWorkspaceName.map { Workspace.get(byName: $0) } }

// Used by focus-back-and-forth
@MainActor private var _prevFocus: FrozenFocus? = nil
@MainActor var prevFocus: LiveFocus? { _prevFocus?.live.takeIf { $0 != focus } }

@MainActor private var onFocusChangedRecursionGuard = false
// Back-and-forth history with a dwell requirement. Recording every focus
// change as "previous" meant supervision machinery — workspace restore,
// distribution across monitors, pill dances — polluted the history with
// workspaces nobody had been to: $mod+tab then bounced to an empty
// workspace and (since empty workspaces materialize on the focused
// monitor) spawned it there. A workspace becomes "previous" only when it
// was held for a beat before leaving (it was a place, not a hop), and the
// history only commits once the destination has itself been held for a
// beat (it was an arrival, not a stop along the way). A round trip that
// starts and ends on the same workspace commits nothing.
@MainActor private var focusedWorkspaceSince: Date = .now
@MainActor private var pendingPrevWorkspaceName: String? = nil
private let workspaceDwell: TimeInterval = 1.0

// Should be called in refreshSession
@MainActor func checkOnFocusChangedCallbacks_nonCancellable() async {
    if refreshSessionEvent?.isStartup == true {
        return
    }
    let focus = focus
    let frozenFocus = focus.frozen
    var hasFocusChanged = false
    var hasFocusedWorkspaceChanged = false
    var hasFocusedMonitorChanged = false
    if frozenFocus != _lastKnownFocus {
        _prevFocus = _lastKnownFocus
        hasFocusChanged = true
    }
    if let pending = pendingPrevWorkspaceName,
       pending != frozenFocus.workspaceName,
       focusedWorkspaceSince.distance(to: .now) >= workspaceDwell {
        _prevFocusedWorkspaceName = pending
        pendingPrevWorkspaceName = nil
    }
    // The workspace we actually came from — for the change callback below,
    // which must report the literal transition even when the back-and-forth
    // history (dwell-filtered) ignores it.
    let cameFromWorkspace = _lastKnownFocus.workspaceName
    if frozenFocus.workspaceName != _lastKnownFocus.workspaceName {
        if focusedWorkspaceSince.distance(to: .now) >= workspaceDwell {
            pendingPrevWorkspaceName = cameFromWorkspace
        }
        focusedWorkspaceSince = .now
        hasFocusedWorkspaceChanged = true
    }
    if frozenFocus.monitorId_oneBased != _lastKnownFocus.monitorId_oneBased {
        hasFocusedMonitorChanged = true
    }
    _lastKnownFocus = frozenFocus

    if onFocusChangedRecursionGuard { return }
    onFocusChangedRecursionGuard = true
    defer { onFocusChangedRecursionGuard = false }
    if hasFocusChanged {
        _ = await onFocusChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, focus)
    }
    if hasFocusedWorkspaceChanged {
        onWorkspaceChanged(cameFromWorkspace, frozenFocus.workspaceName, focus)
    }
    if hasFocusedMonitorChanged {
        _ = await onFocusedMonitorChanged(.defaultEnv, CmdIoImpl.emptyStdinIgnoringOut, focus)
    }
}

@MainActor func onFocusedMonitorChanged(_ env: CmdEnv, _ io: CmdIo, _ focus: LiveFocus) async -> Int32ExitCode {
    broadcastEvent(.focusedMonitorChanged(
        workspace: focus.workspace.name,
        monitorId_oneBased: focus.workspace.workspaceMonitor.monitorId_oneBased ?? 0,
    ))
    return await config.onFocusedMonitorChanged.run(env.withFocus(focus), io)
}

@MainActor func onFocusChanged(_ env: CmdEnv, _ io: CmdIo, _ focus: LiveFocus) async -> Int32ExitCode {
    broadcastEvent(.focusChanged(
        windowId: focus.windowOrNil?.windowId,
        workspace: focus.workspace.name,
    ))
    return await config.onFocusChanged.run(env.withFocus(focus), io)
}

@MainActor private func onWorkspaceChanged(_ oldWorkspace: String, _ newWorkspace: String, _ focus: LiveFocus) {
    broadcastEvent(.workspaceChanged(
        workspace: newWorkspace,
        prevWorkspace: oldWorkspace,
    ))
    if let exec = config.execOnWorkspaceChange.first {
        let process = Process()
        process.executableURL = URL(filePath: exec)
        process.arguments = Array(config.execOnWorkspaceChange.dropFirst())
        var environment = config.execConfig.envVariables
        environment[AEROSPACE_FOCUSED_WORKSPACE] = newWorkspace
        environment[AEROSPACE_PREV_WORKSPACE] = oldWorkspace
        switch focus.asLeaf {
            case .emptyWorkspace(let w):
                environment[AEROSPACE_WORKSPACE] = w.name
                environment[AEROSPACE_WINDOW_ID] = nil
            case .window(let w):
                environment[AEROSPACE_WORKSPACE] = nil
                environment[AEROSPACE_WINDOW_ID] = w.windowId.description
        }
        process.environment = environment
        _ = Result { try process.run() }
    }
}
