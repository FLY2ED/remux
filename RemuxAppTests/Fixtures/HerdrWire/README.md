# HerdrWire golden fixtures

Byte streams recorded from the official Herdr v0.9.3 macOS arm64 binary (tag `v0.9.3`, commit
`7b116c05`), each through `herdr --session NAME remote-client-bridge` on an isolated server with its
own `HOME` and XDG directories. One file pair per recorded client:

- `herdr-<scenario>-<client>.s2c.bin`: every byte the server sent, framed as on the wire.
- `herdr-<scenario>-<client>.c2s.bin`: every byte the client sent (omitted for the 1 MiB paste).
- `herdr-<scenario>-<client>.expected.json`: each server message's offset, payload length, tag and
  decoded fields in Herdr's serde JSON layout (`delta`, `scroll` and `reuse` add the decoded surface
  encodings), and each client message with its exact bytes. Decoded by an independent reference
  decoder whose rebuilt screens matched Herdr's own `pane.read`. `negotiated` is the hello's delta and
  scroll flags; on each surface message, `decoded` is what that decoder's baseline expansion produced,
  as SHA-256 digests of the cells or patch rows (the layout is in `HerdrSurfaceDecoderTests.digest`).
  `final` is the reference presentation's committed surface after the whole recording and its
  count of rejected patches.

`herdr-wide-cells-patch-A` draws CJK, emoji, ZWJ sequences, flags, skin tones, VS16 and VS15,
combining marks, voiced halfwidth kana and a link in one pane of a split, through full surfaces and
patches.

`herdr-graphics-placements-A` holds two single messages from a recording of a PNG shown with the kitty
graphics protocol: a delta and a full surface that place the picture without carrying its bytes (the
picture itself is 3 MB). Its asset fingerprint is above 2^63.

Scenarios: handshakes with and without the compression flags and the four rejections, patch and
delta, reuse, scroll, surface activation, an inactive connection, resizes, the command lane, health
pings, notifications, bell and clipboard, semantic input, cell styles and wide characters, the paste
limit, and agent view.

## Direct terminal attaches

`direct-terminal-<version>-<scenario>` are recordings of the direct terminal connection that `herdr terminal
attach` makes, from the official Herdr v0.9.3 (`7b116c05`) and v0.9.5 (`7573e821`) macOS arm64 binaries,
each through `herdr --session NAME remote-client-bridge` on an isolated server, with a scripted client that
sends `TerminalHello` (protocol 22) and then attaches to a popup's terminal. The popup's terminal id came from
a client-shell surface of the same server; the popup's pty size was read on the server at each step
(TIOCGWINSZ), and it followed the attach, its resize and the detach.

- `01-shell`: attach to a shell popup at 40x12, type `echo wire`, resize to 44x14, a wheel step of 3
  lines up, then one down, detach.
- `02-refused`: attach while another direct client holds the popup, without takeover.
- `03-missing`: attach to a terminal id the server doesn't have.
- `04-exit`: attach, then type `exit`, which ends the popup's shell.
- `05-keyboard`: attach to a popup whose program asked for the kitty keyboard protocol (flags 1).
- `06-grapheme`: attach to a shell popup at 40x12, clear it and print a joined emoji (man, ZWJ, woman, ZWJ,
  girl) followed by ` X`, detach. Herdr writes the emoji as one cell's text, then moves to the next cell.

`.expected.json` lists each server message's offset, payload length, tag and fields (a terminal frame's bytes
as their SHA-256), and each client message's bytes in hex with its fields, decoded by an independent
reference decoder of Herdr's `ServerMessage` and `ClientMessage` (bincode, standard config).
