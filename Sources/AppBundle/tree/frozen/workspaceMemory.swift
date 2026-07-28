import AppKit
import Common

/// Second line of defence against native Spaces.
///
/// When the user visits another Space (a fullscreen app's, or an extra
/// desktop), every window on the departed Space can turn AX-invisible; slow
/// machines then time out the AX calls, the windows get garbage collected,
/// and on return each one re-registers as if brand new — landing on whatever
/// workspace happens to be focused. One Space round trip scrambles the whole
/// layout. The closedWindowsCache next door survives the happy path, but it
/// is reset by every tree-mutating command and restores all-or-nothing (it
/// stops at the first window that hasn't re-registered yet), so on a busy
/// machine it is usually gone or partial by the time the windows come home.
///
/// This is the dumb, durable complement: at garbage-collect time remember
/// which workspace the window lived on; when the same window id re-registers,
/// bind it there instead of to the focused workspace. Nothing resets it, it
/// judges each window alone, and window ids are stable for the life of the
/// window — a Space trip doesn't destroy the window, only our sight of it.
@MainActor private var workspaceMemory: [UInt32: (workspace: String, when: Date)] = [:]
private let workspaceMemoryTtl: TimeInterval = 4 * 3600

@MainActor func rememberWorkspace(windowId: UInt32, _ workspaceName: String) {
    if workspaceMemory.count > 512 {
        workspaceMemory = workspaceMemory.filter {
            $0.value.when.distance(to: .now) < workspaceMemoryTtl
        }
    }
    workspaceMemory[windowId] = (workspaceName, .now)
}

@MainActor func recallWorkspace(windowId: UInt32) -> Workspace? {
    guard let entry = workspaceMemory[windowId],
          entry.when.distance(to: .now) < workspaceMemoryTtl else { return nil }
    return Workspace.get(byName: entry.workspace)
}
