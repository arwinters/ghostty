# Writing a Status Lab plugin

A plugin is any executable that writes JSON lines to stdout. Ghostty draws them in the
status bar. Any language works; the bundled plugins are single Swift files and the
example package is plain `sh`.

## The protocol (version 1)

Write one record per line, at least every ten seconds. Each record replaces everything
the plugin showed before:

```json
{"version":1,"widgets":[{"id":"cpu","label":"CPU","value":"23%","color":"5CC8FF","history":[0.1,0.3,0.23]}]}
```

| Field | Required | Rules |
| --- | --- | --- |
| `id` | yes | Unique within the plugin, up to 64 characters |
| `label` | yes | Up to 32 characters |
| `value` | yes | Up to 64 characters |
| `color` | no | Six hexadecimal digits, `RRGGBB` |
| `history` | no | Up to 60 numbers in 0…1, drawn as a line graph |
| `bars` | no | Up to 64 numbers in 0…1, drawn as blocks (for example one per CPU core) |
| `barColors` | no | One `RRGGBB` per entry in `bars` |
| `symbol` | no | An SF Symbol name such as `cloud.sun.fill`, drawn before the value |

At most 12 widgets per plugin and 16 KiB per record. Text is shown as plain text, never
interpreted as markup, commands or terminal escapes.

**Environment.** Ghostty starts the plugin with `PATH=/usr/bin:/bin:/usr/sbin:/sbin`,
`LANG` and `GHOSTTY_PLUGIN_PROTOCOL=1`, the root directory as working directory, and no
stdin; stderr is discarded. Do not rely on your shell profile, and do not start
background processes: when Ghostty closes the pipe, the plugin should exit.

**Failures.** Malformed, oversized or silent output stops the plugin. It is restarted
after 2, 4, 8, 16, 32 and then every 60 seconds, without affecting other plugins.

**Testing.** Run the plugin in a terminal: it should print one valid line at a time.

## Plugin packages

To share a plugin, put it in a folder with a `plugin.json`:

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
| `name` | yes | 1–64 characters |
| `version` | yes | 1–32 characters |
| `executable` | yes | A path inside the folder, executable (`chmod +x`); links may not lead outside it |
| `description` | no | Up to 300 characters |
| `author` | no | Up to 64 characters |
| `homepage` | no | An `https` link |
| `arguments` | no | Up to 32 strings, passed as they are (no shell) |
| `position` | no | `leading` (left, default), `trailing` (right) or `end` (far right) |
| `protocol` | no | `1` |

Publish the folder, for example as a GitHub repository. Users install it with **Plugin
Manager › Install Plugin…**, which checks the package and copies it into the app, so it
keeps working when the download is moved. Installing the same `id` again updates it.
[`Plugins/battery`](Plugins/battery) is a complete example.

A plain executable can also be added without a package: **Plugin Manager › Add
Executable…**.

## Bundled plugins

| Plugin | Source | Data |
| --- | --- | --- |
| System Stats | [`Plugins/system-stats.swift`](Plugins/system-stats.swift) | CPU per core, memory, network, disk space and activity. Local only. |
| Weather | [`Plugins/weather.swift`](Plugins/weather.swift) | Current conditions from Open-Meteo for a place you choose; only its coordinates are sent. |
| Clock | [`Plugins/clock.swift`](Plugins/clock.swift) | Date and time from a locale-aware template. |

Build one with `swiftc -O Plugins/clock.swift -o clock`.

## Trust and limits

Plugins run with your permissions and are not sandboxed. The protocol limits what a
plugin can show, not what it can do on your Mac: install only plugins you trust. There
is no catalog, automatic download, update check or signature verification. A downloaded
compiled executable may need to be allowed under System Settings › Privacy & Security;
scripts are not affected. At most eight plugins run at the same time.

This is a small, experimental interface, not a stable Ghostty API.
