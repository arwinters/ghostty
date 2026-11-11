# Native status plugins (experimental macOS prototype)

This branch adds an opt-in, process-based plugin interface to Ghostty. Its first
capability is a native status bar below the entire split tree. The host displays
the active pane's working directory and uses it for the tab/window title when
available; that directory is not passed to plugin processes. The example plugin
shows CPU, approximate physical RAM use, and network receive/transmit rates with
60-sample sparklines. No tmux, shell replacement, or prompt integration is needed.

**This is a review prototype, not an accepted Ghostty feature or a stable plugin
API. Stock Ghostty 1.3.1 cannot load it.** It requires a build of this branch until
and unless upstream accepts and releases an implementation. The proposal avoids
maintaining a permanent fork as its intended distribution strategy; it cannot
promise upstream adoption. Linux does not yet render these plugins.

## Try it as a separate app

[`status-lab/`](status-lab/README.md) builds this branch as "Ghostty Status Lab.app", with
its own identity and settings, beside your normal Ghostty:

```sh
python3 examples/status-plugins/status-lab/build.py --bundle-id com.yourname.ghostty.statuslab
```

It bundles the plugins below and adds the Plugin Manager, Session Manager, tmux panes,
Restart Terminal and a compact tab strip.

## Build and try

Follow the root `HACKING.md` and `macos/AGENTS.md` for the required Zig, Xcode,
Metal toolchain, and Nushell versions. From this checkout:

```sh
zig build -Demit-macos-app=false
macos/build.nu --configuration ReleaseLocal
swiftc -O examples/status-plugins/system-stats.swift -o /tmp/ghostty-system-stats
```

Create `/tmp/ghostty-status-plugins.json`:

```json
{
  "version": 1,
  "plugins": [
    {
      "id": "system-stats",
      "executable": "/tmp/ghostty-system-stats",
      "arguments": ["en0"]
    }
  ]
}
```

Use the interface carrying your traffic. On macOS, `route -n get default` shows
it as `interface:`. `en0` is only an example, not an automatic selection. VPN
traffic and interface switching need deliberate interface selection in this v1.

Create a separate `/tmp/ghostty-status-test.config`:

```ini
# Experimental native status plugin manifest (absolute path required)
macos-status-plugins = /tmp/ghostty-status-plugins.json

# Appearance
background = 000000
split-divider-color = 5cc8ff

# Keep the test instance independent from normal session restoration
window-save-state = never
```

Launch the branch build directly with its own configuration:

```sh
macos/build/ReleaseLocal/Ghostty.app/Contents/MacOS/ghostty \
  --config-default-files=false --config-file=/tmp/ghostty-status-test.config
```

Do not replace your installed Ghostty.app for this experiment. The test build
uses Ghostty's normal application identity, so avoid running it alongside a
production instance if you rely on OS session restoration or AppleScript by name.

For a longer-lived experiment, use a trusted, user-owned directory instead of
`/tmp` and update both absolute paths. There is no automatic download, discovery,
or installation of plugin executables.

## Configuration and lifecycle

`macos-status-plugins` is unset by default. When unset or empty there is no bar,
no timer, and no child process. The setting contains an absolute path to a JSON
manifest, with at most eight plugins and unique IDs. Executable paths must also
be absolute. `arguments` is an array; no shell parsing or tilde expansion occurs.

All windows share one set of plugin processes. The bar spans each container's native
splits. It occupies 30 points outside the terminal grid, so shell output and full-screen
applications cannot overwrite it. On narrow windows the bar scrolls horizontally rather
than squeezing terminal columns. The plugins stop when the last bar closes and start
again with the next one.

Changing the configured manifest **path** reloads the host. When the host reports
an error, Reload Configuration or the bar's **Restart plugins** button restarts
its plugins without closing terminals. Healthy hosts are not restarted by an
unrelated configuration reload. Editing a healthy manifest or executable at the
same path still requires reopening the container or changing the manifest path.

Plugin failure removes its values and displays an error. Each failed plugin is
automatically retried after 2, 4, 8, 16, 32, then 60 seconds, capped at once per
minute until recovery. Healthy siblings are not restarted. Backoff resets only
after 60 seconds of healthy operation. Failure reasons and delays are recorded
in macOS unified logging (category StatusPlugins). Stop cancels pending retries,
sends SIGTERM and, after one second, SIGKILL if necessary. A replacement waits
until the old process has exited. Plugins must be single foreground processes; descendant process-tree
management is not implemented. Do not daemonize or launch background children.

## Protocol v1: status capability

The plugin writes UTF-8 JSON records, each terminated by a newline, to stdout.
Each record is a complete snapshot replacing that plugin's widgets:

```json
{"version":1,"widgets":[{"id":"cpu","label":"CPU","value":"23%","color":"5CC8FF","history":[0.1,0.3,0.23]}]}
```

- At most 12 widgets per plugin; IDs are unique within a plugin.
- `id`, `label`, and `value` are plain strings limited to 64, 32, and 64 characters.
- `color` is exactly six hexadecimal digits (RRGGBB).
- `history` is optional, at most 60 finite numbers in the range 0...1.
- `bars` is optional, at most 64 finite numbers in the range 0...1. It is drawn as a
  block graph (for example one block per CPU core) instead of the `history` sparkline.
- `barColors` is optional: one RRGGBB per entry in `bars`, for example to tell
  performance and efficiency cores apart.
- `symbol` is optional: an SF Symbol name (lowercase letters, digits and dots, for
  example `cloud.sun.fill`), drawn by the host before the value.
- Records are limited to 16 KiB. Partial records across pipe reads are supported.
- Send a fresh snapshot at least every ten seconds, even if values are unchanged.
- The host polls twice per second in common run-loop modes and consumes at most
  64 KiB per poll per plugin. One buffered burst is drained across polls; three
  consecutive full batches stop the plugin as a sustained backlog. Individual
  records remain limited to 16 KiB. Malformed or stale output also stops it.
- Heartbeat timing uses system uptime. After a polling gap longer than five
  seconds, the producer gets a fresh heartbeat grace period.
- stdin and stderr go to the null device. Run plugins manually for diagnostics.
- The process receives a minimal PATH/LANG and `GHOSTTY_PLUGIN_PROTOCOL=1`.
  Terminal input, output, working directories, and inherited credentials are
  not supplied through the API.

This is intentionally a small plugin framework with a single rendering
capability. It is not a general-purpose scripting engine, marketplace, or binary
ABI. Plugins can be authored in any language that can emit the protocol. Further
capabilities need separate design review and protocol versioning.

### Placement

A manifest entry may set `"position": "leading"` (default, after the working directory),
`"position": "trailing"` (right side, before the app's own controls) or
`"position": "end"` (far right, after the app's controls; the clock's default).
Other values reject the manifest.

## Plugin packages

A plugin package is how a plugin is shared: a folder with a `plugin.json` and the
executable it names. Status Lab's Plugin Manager installs it with **Install Plugin…**,
which validates the package and copies the folder into the app's Application Support
directory (`plugins/<id>-<random>/`), so the plugin keeps working when the download is
moved. Installing a package with the same `id` again updates it and keeps the user's
choices; uninstalling removes the copy when the change is applied.

```json
{
  "id": "battery",
  "name": "Battery",
  "version": "1.0.0",
  "description": "Charge and charging state of the battery.",
  "author": "Your Name",
  "homepage": "https://github.com/you/ghostty-battery",
  "executable": "battery.sh",
  "arguments": [],
  "position": "trailing",
  "protocol": 1
}
```

| Field | Required | Rules |
| --- | --- | --- |
| `id` | yes | 1–64 lowercase letters, digits, `.`, `-`, `_`; not `system-stats`, `weather` or `clock` |
| `name` | yes | 1–64 characters, shown in the Plugin Manager |
| `version` | yes | 1–32 characters, for example `1.2.0` |
| `executable` | yes | Path inside the folder; it must be executable (`chmod +x`). Links may not lead outside the folder. |
| `description` | no | Up to 300 characters |
| `author` | no | Up to 64 characters |
| `homepage` | no | An `https` link |
| `arguments` | no | Up to 32 strings, passed as-is (no shell) |
| `position` | no | `leading` (default), `trailing` or `end` |
| `protocol` | no | Status protocol version; only `1` exists |

[`packages/battery`](packages/battery) is a complete example in plain `sh`. To publish a
plugin, put its folder in a repository with a short README; users download the folder
and install it. There is no catalog, automatic download or update check, and no
signature verification: users should install only plugins they trust. A downloaded
compiled executable may need to be allowed under System Settings › Privacy & Security;
scripts run through their interpreter and are not affected.

Test a plugin by running it in a terminal: it should print one JSON record per line, at
least every ten seconds. Ghostty starts it with a minimal environment
(`PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `LANG`, `GHOSTTY_PLUGIN_PROTOCOL=1`), the root
directory as working directory and no stdin, so do not rely on your shell profile.

## Bundled plugins (Status Lab builds)

| Plugin | Source | Data |
| --- | --- | --- |
| System Stats | `system-stats.swift` | CPU (line or per-core blocks), RAM, network down/up, disk space, disk read/write. Local only. |
| Weather | `weather.swift` | Current conditions from Open-Meteo for configured coordinates; refreshed every 15 minutes. |
| Clock | `clock.swift` | Day, date, year and time from a locale-aware `DateFormatter` template. |

Each is a single Swift file: `swiftc -O weather.swift -o weather`. They double as
examples for other plugins. Status Lab's Plugin Manager writes the manifest from
its settings (`plugins.settings.json` → `plugins.generated.json` in the app's
Application Support directory), installs plugin packages and lets users add any other
protocol v1 executable.

## tmux panes (Status Lab builds)

tmux is not a status plugin: it opens panes. Profiles (name, directory, command,
resume command) are configured in the Plugin Manager and opened from the Plugins menu.
Each pane runs `tmux new-session` (or attaches when the session exists) through the
user's login shell, so tools such as `claude` are on `PATH`. Right-clicking a pane
shows a tmux submenu with the profiles and all detached sessions, to open as a split
next to that pane or as a new tab. Session names are
`ghostty-<profile>-<random>`.

The tmux server does not belong to Ghostty. When none is running, Ghostty starts it as a
launchd job of the user (`tmux -D` in the login environment; `tmux-server.plist` in the
app's Application Support directory). Quitting Ghostty, a crash or a Force Quit therefore
only ends the tmux clients in its panes; the sessions and the programs in them keep
running and can be attached from any terminal (**Copy Attach Command** in the pane's
tmux menu: `tmux attach -t ghostty-claude-ab12`). Quitting does not ask for confirmation
when only tmux panes are busy. A server that is already running, whoever started it, is
used as it is.

The Session Manager stores the tmux session per pane, and its output read from tmux
(`capture-pane`): the visible screen with the regular checkpoints, the last 3000 lines
when quitting and before sleep. A restore reattaches when the session still runs. After
a restart or shutdown the server is gone; restore recreates the session in the saved
directory, prints the saved history and then runs the resume command (default for
Claude: `claude --continue`, or a login shell when Claude had already exited). When the
command exits, the pane keeps a login shell. Closing a pane detaches it; end sessions
from the Plugin Manager.

## AI sessions (Status Lab builds)

Right-click a pane › **New AI Session** starts an AI coding tool in a tmux session in that
pane's directory, as a split or a new tab (also in the Plugins menu, starting in the
focused pane's directory). Because it runs in tmux, it keeps running when Ghostty quits
and can be attached from any terminal; after a restart the session comes back with its
saved history and the tool's resume command.

The tools are set in the Ghostty configuration, one line each:

```ini
macos-ai-session = name:Claude Code,command:claude,resume:claude --continue
macos-ai-session = name:Codex,command:codex,resume:codex resume --last
```

`name` is the menu title, `command` what runs (through the login shell, so tools
installed with npm, Homebrew or an install script are found), `resume` what runs when a
saved session is restored after its tmux session ended (optional; defaults to
`command`). Quote a value that contains a comma. A tool whose program is not found in
the login shell is shown disabled. `macos-ai-session =` on its own removes all entries.
The Plugin Manager's AI Sessions page shows the configured tools, whether each is
installed, and configuration errors. Ghostty itself never talks to an AI service and
stores no keys: it only starts the command-line tools you installed.

## Example metrics

The Swift example reads macOS counters once per second without shelling out:

- CPU: deltas of aggregate CPU ticks, normalized across all cores to 0–100%.
- RAM: active + wired + compressor pages, capped at physical RAM. This is an
  approximation, not Activity Monitor's exact memory accounting or pressure.
- Network: deltas of the selected interface's byte counters, divided by monotonic
  elapsed time. Initial readings and resets are not represented as zero traffic.
- CPU/RAM graphs use a fixed 0–100% scale. Each network graph scales to its own
  rolling 60-sample peak; download and upload graph heights are not comparable.

History is kept in memory only. Metrics describe this Mac, not a remote SSH host.

## Trust and limits

**Plugins run with the user's permissions and are not sandboxed.** Restricting
the protocol and environment does not prevent an executable from reading files,
using the network, or starting other processes. Enable only manifests and
executables you trust. There is no signature verification or permission broker.
The host never interprets labels as markup, shell commands, or terminal escapes.

This prototype establishes bounded parsing and UI updates, not a full security
boundary. File permissions, signing, process-tree cleanup, shared instances
across windows, error diagnostics, localization, GTK support, and API stability
need upstream design decisions before a production release.

## Validation

Protocol and host tests live in `macos/Tests/StatusPlugins/StatusPluginTests.swift`.
Run the app's tests with `macos/build.nu --action test`. The suite covers framed
updates, malformed/oversized records, duplicate IDs, manifest validation,
disabled operation, and child exit reporting. See `VALIDATION.md` in this folder
for the actual checks completed for this branch and remaining manual checks.

Manual checks before acceptance: multiple windows/tabs, quick terminal, split
creation/resizing/zooming, config enable/disable/reload, narrow window scrolling,
VoiceOver, sleep/wake, plugin exit/hang/flood, and interactive programs such as
Vim and Claude Code. Verify process counts after repeatedly closing containers.

## Upstream review

This is an AI-assisted prototype: OpenAI Codex generated the initial design,
implementation, documentation, and tests under human direction. The contributor
must review and understand the implementation before submitting it upstream.
See the root `CONTRIBUTING.md` and `AI_POLICY.md`. A published branch is not an
upstream submission; feature design belongs in a human-reviewed discussion,
and new contributors need the project's vouch process before opening a PR.
