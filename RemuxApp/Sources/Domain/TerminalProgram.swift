/// What runs in a pane, as the Tabs sheet marks it: a coding agent, by its kind, or a terminal, for a shell
/// and any other program.
enum TerminalProgram: Hashable, Sendable {
    /// An agent by its kind's name: Herdr's name for an agent it knows (`detect/mod.rs` `agent_label`), else
    /// the name its hooks report.
    case agent(String)
    case terminal
}
