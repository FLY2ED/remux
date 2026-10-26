/// The commands that run tmux on a server, through `RemoteProgramCommand`: the SSH login shell only parses
/// the wrapper, so fish and csh need not understand POSIX syntax.
enum SSHTmuxControlCommandBuilder {
    /// Asks tmux by the session's name as tmux keeps it; `=` makes tmux match it exactly, where it would otherwise
    /// take a session whose name starts with it.
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
            arguments: [TmuxSessionName.kept(sessionName)],
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

/// A session's name as tmux keeps it: tmux turns ':' and '.' into '_' when it names a session, so `work.api`
/// is `work_api` on the server.
enum TmuxSessionName {
    static func kept(_ name: String) -> String {
        String(name.map { $0 == ":" || $0 == "." ? "_" : $0 })
    }
}
