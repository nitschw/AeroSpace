public struct SummonWorkspaceCmdArgs: CmdArgs {
    /*conforms*/ public var commonState: CmdArgsCommonState
    public init(rawArgs: StrArrSlice) { self.commonState = .init(rawArgs) }
    public static let parser: CmdParser<Self> = .init(
        kind: .summonWorkspace,
        help: summon_workspace_help_generated,
        flags: [
            "--fail-if-noop": trueBoolFlag(\.failIfNoop),
            // Panewright extensions: heal a monitor stuck on an auto-invented
            // workspace without disturbing the user's focus.
            "--on-monitor": singleValueSubArgParser(\.onMonitor, "<monitor-id>", parseUInt32),
            "--no-focus": trueBoolFlag(\.noFocus),
        ],
        posArgs: [
            dashDashArg(mandatory: false),
            newMandatoryPosArgParser(\.target, parseWorkspaceName, placeholder: "<workspace>"),
        ],
    )

    public var target: Lateinit<WorkspaceName> = .uninitialized
    public var failIfNoop: Bool = false
    /// Set the workspace active on this monitor instead of the focused one.
    public var onMonitor: UInt32? = nil
    /// Make it visible without moving focus to it.
    public var noFocus: Bool = false
}

private func parseWorkspaceName(i: PosArgParserInput) -> ParsedCliArgs<WorkspaceName> {
    .init(WorkspaceName.parse(i.arg), advanceBy: 1)
}
