/// The commands that run tmux on a server, through `RemoteProgramCommand`: the SSH login shell only parses
/// the wrapper, so fish and csh need not understand POSIX syntax.
enum SSHTmuxControlCommandBuilder {
    /// `=` makes tmux match the name exactly; without it, tmux takes a session whose name starts with it.
    static func controlSessionCommand(
        tmuxExecutable: String,
        sessionName: String,
        opening: SessionOpening,
        initialViewport: TmuxControlViewport
    ) -> String {
        let open = switch opening {
        case .attach:
            #"exec "$resolved" -u -C attach-session -t "=$session""#
        case .create:
            #"exec "$resolved" -u -C new-session -A -s "$session" -x \#(initialViewport.columns) -y \#(initialViewport.rows)"#
        }
        return RemoteProgramCommand.command(
            program: tmuxExecutable,
            arguments: [sessionName],
            body: [
                "TERM=xterm-256color",
                "export TERM",
                #"session=$(printf %b "$2")"#,
                open,
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
