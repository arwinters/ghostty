# Ghostty Status Lab

Status Lab is an experimental build of Ghostty for macOS that adds the things I missed
after switching from iTerm2: a plugin-driven status bar, a session manager that survives
crashes, tmux panes for long-running sessions such as Claude Code, and a way to restart
a stuck pane. It is packaged as a separate app, so you can try it next to your normal
Ghostty without changing anything there.

**This is an experiment, not an official Ghostty release and not a pull request.** I am
sharing it to start a conversation about which of these ideas could fit Ghostty.

## Why this exists

I used iTerm2 for about fifteen years. Over time a few small irritations added up, so I
wanted to try something else and ended up with Ghostty: fast, native and pleasant to use.
What I missed were the plugins and habits I had built up in iTerm2 over all those years:

- a status bar with CPU, memory, network, disk, weather and the time, always visible;
- getting my windows, tabs and splits back after a crash or an unexpected restart;
- long-running sessions (in my case Claude Code) that keep running when the terminal
  goes away, and come back where I left them;
- restarting a pane that has completely hung, without closing the whole window.

There were also a few small UI annoyances: stretched titlebar tabs, a context menu entry
with an unclear name, and a tab with many panes that closed without asking.

I built these changes myself with the help of AI coding agents (OpenAI Codex and
Anthropic Claude), over a few days of daily use and iteration. In my opinion the result
now has a well-working session manager and plugin manager, and I would like to share the
code with the community. Take what is useful; I expect much of it to change, or be done
differently, if any of it is ever considered for Ghostty itself.

## What is in it

| Feature | What it does | Where |
| --- | --- | --- |
| Status bar plugins | A bar below the splits, outside the terminal grid. Plugins are separate processes that write small JSON snapshots; they never touch terminal input or output. | Bottom of every window |
| System Stats | CPU with one block per core (performance cores blue, efficiency cores teal), memory, network down/up, disk space, disk read/write. Compact block graphs or line graphs. Local only. | Bundled plugin |
| Weather, Clock | Current weather from Open-Meteo (no API key, only your chosen coordinates are sent) and a locale-aware day/date/year/time. | Bundled plugins |
| Plugin Manager | Every plugin, built-in or installed, with its version and whether it is running. Turn plugins on or off, place each one left, right or far right, edit their settings, install plugin packages or add any executable that speaks the protocol. | Plugins menu, ⌥⌘P, or the Plugins button in the bar |
| Session Manager | The open windows always belong to a workspace that saves itself: windows, tabs, splits, ratios, focused pane, directories, titles, font size and recent output. Layout changes are saved within seconds, the visible screen at most once a minute, scrollback before sleep and when quitting. Restores the last workspace at launch, also after a crash. Switch workspaces, open earlier versions, delete several at once. | Sessions menu, ⇧⌘S, or the workspace name in the bar |
| Context menu | Right-click a pane (also inside tmux): copy and paste, tabs and splits, the pane's directory, tmux, workspaces and terminal actions. | Right-click a pane |
| tmux panes | Profiles (default: Claude, `claude`) open a tmux session in a directory you choose, as a split or tab. The tmux server runs as a launchd job, not under Ghostty: quitting or a crash of Ghostty only detaches, and every session can be attached from any terminal. After a restart a session is recreated with its saved history and a resume command (`claude --continue`). tmux's own status line is hidden for these sessions only. | Right-click a pane › tmux |
| Restart Terminal | Stops every process attached to the pane's terminal and starts a new shell in the same place, directory and font size. | Right-click a stuck pane › Restart Terminal… |
| Tab strip | Compact tabs for `macos-titlebar-style = tabs` that keep a sensible width and blend with the background. In fullscreen the tabs are hidden and appear with the menu bar when you move the pointer to the top. | Top of the window |
| Close confirmation | Closing a tab or window with more than one pane always asks first. | Tab close button, Close Tab, window close button |

## Design choices

- **Plugins are data, not code in the app.** A plugin is an ordinary executable that
  writes newline-delimited JSON to stdout: labels, values, colors and optional graphs.
  It cannot draw arbitrary UI or read or write terminals. Output is size-limited and
  validated; a failing plugin is restarted with backoff without affecting the others.
  The protocol is described in [`../README.md`](../README.md).
- **Sessions are owned by the app, not by a plugin.** A crashing status plugin can never
  cost you your workspace. Checkpoints are written atomically, the last 20 automatic
  ones are kept, a damaged file falls back to an older valid one, and an empty window
  list never overwrites a good session. Storage is private to your user account.
- **Restored panes get a new shell.** Running programs cannot be carried across a crash
  or restart; saved output is shown as plain text and is never executed. For programs
  that must keep running, use a tmux pane: tmux runs outside the terminal.
- **Restart Terminal signals the pane's terminal device.** Ghostty normally sends SIGHUP
  to the shell's process group when a pane closes. A hung foreground program has its own
  process group and may ignore that. Restart sends SIGHUP to every process on that
  terminal and SIGKILL to whatever is still alive after 0.8 seconds. Other panes and
  Ghostty itself are not on that terminal.
- **Normal Ghostty builds are unaffected.** All of this is only active when the app's
  Info.plist contains `StatusLabVersion`, which only `build.py` adds.

## Build

Install the toolchain from `HACKING.md` (Zig, Xcode with the Metal toolchain, Nushell),
then from the repository root:

```sh
python3 examples/status-plugins/status-lab/build.py --bundle-id com.yourname.ghostty.statuslab
open "zig-out/status-lab/Ghostty Status Lab.app"
```

Options: `--name`, `--output`, `--build-dir`, `--zig`, `--nu`, and `--skip-core` to reuse
an existing `macos/GhosttyKit.xcframework`. The script copies `macos/` to a build
directory and gives the copy its own identity (bundle id, display name, bootstrap, no
updater, no file handlers). It builds it with `macos/build.nu`, compiles the bundled
plugins and signs the app ad hoc for your Mac. The tracked source tree is not modified.

On first launch the app writes `~/Library/Application Support/<bundle id>/config.ghostty`
from [`status-lab-defaults.config`](status-lab-defaults.config): Dracula on black,
JetBrains Mono, the tab strip, split keybindings and `window-save-state = always`. Edit it
like any Ghostty configuration.

## How it was tested

- 33 Swift tests for the plugin protocol and host, plugin settings and manifest
  generation, session snapshots (corruption fallback, retention, permissions,
  validation) and tmux command quoting (checked against a real shell).
- The tmux flows (create, survive a crash, reattach, recreate after a restart, hidden
  status line) and Restart Terminal (processes that ignore SIGHUP, other panes untouched)
  were checked against real processes.
- Daily use while building it, with many windows, splits and tmux sessions.
- SwiftLint (`--strict`) on all changed Swift files.

## Known limitations

- macOS only. Linux (GTK) has none of this.
- Plugins run with your permissions and are not sandboxed. Only add programs you trust.
- Plugin packages are installed from a folder; there is no catalog, download or update
  check. A downloaded binary may be blocked by Gatekeeper until you allow it in System
  Settings › Privacy & Security; scripts are not affected.
- Workspaces open in place of the open windows; programs in normal panes stop (tmux
  sessions keep running).
- Normal panes restore as new shells with saved output; the programs themselves do not
  come back. Repeated restores currently repeat the "Restored session" marker in the
  saved output.
- Tabs in the tab strip cannot be dragged to reorder or detach; use the `move_tab`
  keybindings.
- Ad-hoc signed: it runs on the Mac that built it. Distribution would need a
  Developer ID and notarization.

## Write and share a plugin

A plugin is any executable that writes the status protocol to stdout. To share one,
put it in a folder with a `plugin.json` (name, version, description, author, homepage)
and publish the folder, for example as a GitHub repository. Users install it with
**Install Plugin…** in the Plugin Manager. See [Plugin packages](../README.md#plugin-packages)
and the example in [`../packages/battery`](../packages/battery).

## Versions

Status Lab has its own version number, independent of Ghostty. See
[`../CHANGELOG.md`](../CHANGELOG.md) for every change from 0.1.0 to now.

Feedback, ideas and criticism are very welcome.
