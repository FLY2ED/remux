import Foundation

/// How Remux runs tmux or Herdr on a server: `exec /bin/sh -c '<script>' sh <program> <arguments>`, with the
/// script in single quotes and every argument octal-encoded, so the user's login shell parses no argument. The
/// script uses no single quote of its own. The shell is named `sh`, so its own errors read like any shell's.
///
/// The script looks for the program on the login PATH, then in the folders package managers install to. When
/// nothing there can run, it exits 127 with `notFoundMarker` on stderr. Otherwise it prints `readyMarker` on a
/// line of its own on stdout and on stderr, then runs the body with the program as `$resolved` and the
/// arguments after it as `$2`, `$3` and so on, still encoded. What follows the marker is the program's, or the
/// shell's report that it couldn't start it; what precedes it came from the server's startup files.
enum RemoteProgramCommand {
    static let readyMarker = "remux-ready:1"
    static let notFoundMarker = "remux: not found"
    /// The name the script's shell runs under, which starts each of its own error lines.
    static let shellName = "sh"

    /// After the user's PATH: where Herdr's client looks for Herdr, mise's shims, MacPorts, Guix and Snap,
    /// then the system folders the script's own tools live in.
    static let fallbackPath = [
        "$HOME/.local/bin",
        "$HOME/.local/share/mise/shims",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/home/linuxbrew/.linuxbrew/bin",
        "$HOME/.nix-profile/bin",
        "/etc/profiles/per-user/${USER:-}/bin",
        "/nix/var/nix/profiles/default/bin",
        "/run/current-system/sw/bin",
        "$HOME/.guix-profile/bin",
        "/run/current-system/profile/bin",
        "/snap/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin",
    ].joined(separator: ":")

    static func command(program: String, arguments: [String] = [], body: [String]) -> String {
        let script = (prelude + body).joined(separator: "; ")
        return (
            ["exec /bin/sh -c '\(script)' \(shellName)", RemoteShellArgument.octalEncoded(program)]
                + arguments.map(RemoteShellArgument.octalEncoded)
        ).joined(separator: " ")
    }

    private static let prelude = [
        #"PATH="${PATH:+$PATH:}\#(fallbackPath)""#,
        "export PATH",
        #"program=$(printf %b "$1")"#,
        #"resolved=$(command -v "$program" 2> /dev/null)"#,
        #"[ -x "$resolved" ] || { echo "\#(notFoundMarker): $program" >&2; exit 127; }"#,
        #"printf "\n%s\n" "\#(readyMarker)""#,
        #"printf "\n%s\n" "\#(readyMarker)" >&2"#,
    ]

    /// The first line the program or the shell running it printed after the ready marker, without the
    /// marker's own copies: on a pty, stdout's and stderr's arrive together. Empty when nothing followed it;
    /// nil when the run never printed it.
    static func programMessage(in output: String) -> String? {
        var readyLine = ReadyLine()
        let rest = readyLine.output(from: Array(output.utf8))
        guard readyLine.isFound else { return nil }
        let lines = String(decoding: rest, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.first { !$0.isEmpty && $0 != readyMarker } ?? ""
    }

    /// What a run that ended before the ready marker printed last: the login shell's or the server's startup
    /// files' own words. The cause is usually at the end, after any greeting, and a shell's error can take a
    /// few lines (fish names the file and line, then marks the spot). nil when it printed nothing.
    static func startupMessage(in output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { String($0.reversed().drop(while: \.isWhitespace).reversed()) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        return lines.suffix(startupMessageLineLimit).joined(separator: "\n")
    }

    private static let startupMessageLineLimit = 6

    /// Skips a stream up to the end of the ready marker's line, as Herdr's client does with its own: the
    /// first line that is exactly the marker, optionally ending in a carriage return.
    struct ReadyLine: Equatable, Sendable {
        private static let marker = Array(RemoteProgramCommand.readyMarker.utf8)
        private(set) var isFound = false
        private var matched = 0
        private var matching = true

        /// The bytes after the marker's line; nothing until it has been seen.
        mutating func output(from bytes: some Collection<UInt8>) -> [UInt8] {
            guard !isFound else { return Array(bytes) }
            var index = bytes.startIndex
            while index != bytes.endIndex {
                let byte = bytes[index]
                index = bytes.index(after: index)
                if byte == 0x0A {
                    if matching, matched == Self.marker.count {
                        isFound = true
                        return Array(bytes[index...])
                    }
                    matched = 0
                    matching = true
                } else if matching, matched < Self.marker.count, byte == Self.marker[matched] {
                    matched += 1
                } else if matching, matched != Self.marker.count || byte != 0x0D {
                    matching = false
                }
            }
            return []
        }
    }
}

/// A run's messages as they arrive, kept bounded for `RemoteProgramFailure`: until the ready marker, the end of
/// them, where the not-found line and the login shell's errors are; from the marker on, what follows it, where
/// the program's or the shell's first line is, however much the program prints after it.
struct RemoteProgramMessages: Equatable, Sendable {
    private static let limit = 8 * 1024

    private var readyLine = RemoteProgramCommand.ReadyLine()
    private var bytes = Data()

    var text: String {
        String(decoding: bytes, as: UTF8.self)
    }

    mutating func append(_ data: Data) {
        guard !readyLine.isFound else {
            bytes.append(data.prefix(max(0, Self.limit - bytes.count)))
            return
        }
        let afterMarker = readyLine.output(from: data)
        if readyLine.isFound {
            bytes = Data("\n\(RemoteProgramCommand.readyMarker)\n".utf8) + afterMarker.prefix(Self.limit)
        } else {
            bytes.append(data)
            if bytes.count > Self.limit {
                bytes.removeFirst(bytes.count - Self.limit)
            }
        }
    }
}

/// How a run through `RemoteProgramCommand` failed, once the script got as far as looking for the program.
enum RemoteProgramFailure: Error, Equatable, Sendable {
    /// Nothing that can run was found by that name or at that path.
    case notFound
    /// The shell found it but couldn't start it, in the shell's words.
    case couldNotStart(String)
    /// It ran and failed, in its own words; empty when it said nothing.
    case failed(String)

    /// Reads a failed run's exit status and its stderr, which on a pty is everything it printed. nil when the
    /// run ended before the script got to the program: the login shell or the server's startup files failed.
    init?(exitStatus: Int, stderr: String) {
        if exitStatus == 127, stderr.contains(RemoteProgramCommand.notFoundMarker) {
            self = .notFound
            return
        }
        guard let message = RemoteProgramCommand.programMessage(in: stderr) else { return nil }
        // A shell that can't start the program says so in a line that starts with its name. Its exit status
        // doesn't tell: dash, bash 5 and busybox exit 126 or 127, macOS's /bin/sh (bash 3.2) exits 1 from a failed
        // `exec`, and a program that ran can exit 126 or 127 itself.
        self = message.hasPrefix("\(RemoteProgramCommand.shellName): ") ? .couldNotStart(message) : .failed(message)
    }
}
