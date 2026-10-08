# Native status plugins (experimental macOS prototype)

This branch adds an opt-in, process-based plugin interface to Ghostty. Its first
capability is a native status bar below the entire split tree. The example plugin
shows CPU, approximate physical RAM use, and network receive/transmit rates with
60-sample sparklines. No tmux, shell replacement, or prompt integration is needed.

**This is a review prototype, not an accepted Ghostty feature or a stable plugin
API. Stock Ghostty 1.3.1 cannot load it.** It requires a build of this branch until
and unless upstream accepts and releases an implementation. The proposal avoids
maintaining a permanent fork as its intended distribution strategy; it cannot
promise upstream adoption. Linux does not yet render these plugins.

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

Each visible terminal container starts its own set of plugins. The bar spans
that container's native splits. It occupies 30 points outside the terminal grid,
so shell output and full-screen applications cannot overwrite it. On narrow
windows the bar scrolls horizontally rather than squeezing terminal columns.
Closing/hiding the container stops its plugins; showing it starts them again.

Changing the configured manifest **path** reloads the host. Editing a manifest
or executable at the same path requires reopening the terminal container (or
removing the setting, reloading, restoring it, and reloading again). This avoids
silently relaunching edited executables during unrelated configuration reloads.

Plugin failure removes its values and displays an error. It does not trigger an
automatic restart loop. Stop sends SIGTERM and, after one second, SIGKILL if
necessary. Plugins must be single foreground processes; descendant process-tree
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
- Records are limited to 16 KiB. Partial records across pipe reads are supported.
- Send a fresh snapshot at least every ten seconds, even if values are unchanged.
- The host polls twice per second and consumes at most 64 KiB per poll per plugin.
  Malformed, oversized, excessive, or stale output stops that plugin.
- stdin and stderr go to the null device. Run plugins manually for diagnostics.
- The process receives a minimal PATH/LANG and `GHOSTTY_PLUGIN_PROTOCOL=1`.
  Terminal input, output, working directories, and inherited credentials are
  not supplied through the API.

This is intentionally a small plugin framework with a single rendering
capability. It is not a general-purpose scripting engine, marketplace, or binary
ABI. Plugins can be authored in any language that can emit the protocol. Further
capabilities need separate design review and protocol versioning.

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
