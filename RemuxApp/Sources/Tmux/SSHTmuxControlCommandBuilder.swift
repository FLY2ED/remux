/// The commands that run tmux on a server, through `RemoteProgramCommand`: the SSH login shell only parses
/// the wrapper, so fish and csh need not understand POSIX syntax.
enum SSHTmuxControlCommandBuilder {
    static func attachOrCreateControlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        initialViewport: TmuxControlViewport
    ) -> String {
        RemoteProgramCommand.command(
            program: tmuxExecutable,
            arguments: [sessionName],
            body: [
                "TERM=xterm-256color",
                "export TERM",
                #"session=$(printf %b "$2")"#,
                #"exec "$resolved" -u -C new-session -A -s "$session" -x \#(initialViewport.columns) -y \#(initialViewport.rows)"#,
            ]
        )
    }

    /// Discovery runs on an ordinary SSH exec channel, never the control-mode channel. After the ready marker
    /// it prints where it found tmux, then one session name per line.
    static func listSessionsCommand(tmuxExecutable: String) -> String {
        RemoteProgramCommand.command(program: tmuxExecutable, body: [
            "LC_ALL=C",
            "export LC_ALL",
            #"printf "%s\n" "$resolved""#,
            "exec \"$resolved\" list-sessions -F \"#{session_name}\"",
        ])
    }
}
