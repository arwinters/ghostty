# Ghostty Status Lab

Status Lab is this branch packaged as a separate macOS app, to try the proposal without
replacing Ghostty. It has its own name, bundle identifier, configuration and settings
directory (`~/Library/Application Support/<bundle id>`), never starts the Ghostty
updater, and does not register as a handler for scripts or folders.

**This is an experiment, not an official Ghostty release.** Only build and run it if you
are comfortable with that.

## Build

Install the toolchain from `HACKING.md` (Zig, Xcode with the Metal toolchain, Nushell),
then from the repository root:

```sh
python3 examples/status-plugins/status-lab/build.py --bundle-id com.yourname.ghostty.statuslab
open "zig-out/status-lab/Ghostty Status Lab.app"
```

Options: `--name`, `--output`, `--build-dir`, `--zig`, `--nu`, and `--skip-core` to reuse
an existing `macos/GhosttyKit.xcframework`. The script copies `macos/` to a build
directory, gives the copy the Status Lab identity (bundle id, display name, bootstrap,
no updater), builds it with `macos/build.nu`, compiles the bundled plugins and signs the
result ad hoc for this Mac. The tracked source tree is not modified.

On first launch the app writes `config.ghostty` from `status-lab-defaults.config` (Dracula
on black, JetBrains Mono, tab strip, splits keybindings, `window-save-state = always`).
Edit that file afterwards like any Ghostty configuration.

## What to try

| Feature | Where |
| --- | --- |
| Status bar with plugins | Bottom of every window. System Stats (blocks per CPU core, memory, network, disk), Weather, Clock. |
| Plugin Manager | Plugins menu, ⌥⌘P, or the bar's Plugins button. Position each plugin left, right or far right; add community plugins. |
| Session Manager | Sessions menu, ⇧⌘S, or the bar's Sessions button. Windows, tabs, splits, directories and recent output come back after a quit or crash. |
| tmux panes | Right-click a pane › tmux. Profiles (default: Claude) start in a directory you choose; detached sessions can be reattached. Restored after crashes. |
| Restart Terminal | Right-click a stuck pane › Restart Terminal… Stops everything in that pane and starts a new shell there. |
| Tab strip | `macos-titlebar-style = tabs`: compact tabs that blend in, also in fullscreen. |

Status Lab versions and changes: [`../CHANGELOG.md`](../CHANGELOG.md). Plugin protocol:
[`../README.md`](../README.md).
