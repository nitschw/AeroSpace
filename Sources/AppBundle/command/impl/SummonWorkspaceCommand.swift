import AppKit
import Common

struct SummonWorkspaceCommand: Command {
    let args: SummonWorkspaceCmdArgs
    /*conforms*/ let shouldResetClosedWindowsCache = true

    func run(_ env: CmdEnv, _ io: CmdIo) -> BinaryExitCode {
        let workspace = Workspace.get(byName: args.target.val.raw)
        // Panewright extension: target any monitor, optionally without
        // moving focus — the supervision heal replaces an auto-invented
        // workspace on a background monitor, and doing that by focusing it
        // first raced the user's own workspace switches (landing them on
        // the summoned workspace instead of the one they asked for).
        if let monitorId = args.onMonitor {
            guard let monitor = monitors.first(where: { $0.monitorId_oneBased == Int(monitorId) }) else {
                return .fail(io.err("No monitor with id \(monitorId)"))
            }
            if monitor.activeWorkspace == workspace { return .succ }
            guard monitor.setActiveWorkspace(workspace) else {
                return .fail(io.err("Can't place workspace '\(workspace.name)' on monitor \(monitorId)"))
            }
            return args.noFocus ? .succ : .from(bool: workspace.focusWorkspace())
        }
        let monitor = focus.workspace.workspaceMonitor
        if monitor.activeWorkspace == workspace {
            return switch args.failIfNoop {
                case true: .fail
                case false:
                    .succ(io.err("Workspace '\(workspace.name)' is already visible on the focused monitor. Tip: use --fail-if-noop to exit with non-zero code"))
            }
        }
        let prevMonitor = workspace.isVisible ? workspace.workspaceMonitor : nil
        if monitor.setActiveWorkspace(workspace) {
            if let prevMonitor {
                let stubWorkspace = getStubWorkspace(for: prevMonitor)
                check(
                    prevMonitor.setActiveWorkspace(stubWorkspace),
                    "getStubWorkspace generated incompatible stub workspace (\(stubWorkspace)) for the monitor (\(prevMonitor)",
                )
            }
            return args.noFocus ? .succ : .from(bool: workspace.focusWorkspace())
        } else {
            return .fail(io.err("Can't move workspace '\(workspace.name)' to monitor '\(monitor.name)'. workspace-to-monitor-force-assignment doesn't allow it"))
        }
    }
}
