# Status Lab changelog

## 0.8.0 — 2026-10-14

- Restart Terminal… in the pane context menu, for a stuck pane (like iTerm2's Restart
  Session): every process attached to the pane's terminal device gets SIGHUP and
  SIGCONT, survivors get SIGKILL after 0.8 s, and a new shell starts in the same split,
  directory and font size. Other panes and Ghostty itself are never signalled. No undo
  entry, so the old surface and its processes are not kept alive. tmux panes reattach
  to their session instead. Confirms first when a program is still running.
- "Reset Terminal Display" is now "Clear Garbled Screen" (same action: reset the screen
  and terminal modes, programs keep running).
- tmux profiles ask for the start directory (default on, per profile), starting from
  the clicked or focused pane's directory instead of always $HOME.

## 0.7.1 — 2026-10-14

- tmux panes: Detach Session and End Session in the pane's right-click menu. Detaching
  closes the pane and keeps the session running (inside tmux: Ctrl-b d).
- "Hide tmux status bar" (default on) turns off tmux's own status line for sessions
  opened by Ghostty only (session option); global tmux settings are untouched.
- The status bar shows "tmux · session · directory" for tmux panes, reading the active
  pane's directory from tmux, instead of "Directory unavailable".

## 0.7.0 — 2026-10-14

- tmux in the pane context menu (right-click): open any configured profile, or attach
  any detached tmux session, as Split Right, Split Down or New Tab next to the clicked
  pane. Detached sessions are listed live, including sessions started outside Ghostty;
  attached panes are saved and restored by the Session Manager like profile panes.

## 0.6.0 — 2026-10-14

- Plugin Manager and Session Manager share one window layout (sidebar, grouped form,
  footer) in a plain titled window. Fixes settings hidden under the titlebar, such as
  the weather location field.
- Session Manager pages: Workspaces (save, restore, delete), Automatic checkpoints,
  Before Launch recovery points (delete) and How It Works. Rows show windows, tabs,
  panes and tmux panes. Save Now writes a checkpoint immediately.
- New status bar zone "Far right, after Sessions". The clock defaults to it, so the
  order on the right is: right-hand plugins · Sessions · Plugins · clock.
- System Stats graph style applies to every measurement and defaults to Blocks:
  CPU per core (performance cores blue, efficiency cores teal, performance first),
  memory/network/disk activity as the last 12 seconds, disk space as an 8-block meter.
  Compact fixed-width values (MEM 71/128G, NET ↓ 13k, R/W 865k) keep the bar steady.
  Disk read is now coral to stay distinct from the teal efficiency cores.
- Protocol additions (optional): manifest position "end", widget `barColors`
  (one RRGGBB per bar).

## 0.5.0 — 2026-10-14

- Plugin Manager (Plugins menu, ⌥⌘P, or the Plugins button in the status bar): enable
  plugins, place each one left or right in the status bar, edit their settings, and add
  community plugins (any executable speaking protocol v1). Apply restarts the plugins in
  every window without closing terminals.
- New Weather plugin (Open-Meteo, no API key; place search in the manager; Dutch and
  English condition names; refreshes every 15 minutes).
- New Clock plugin: day, date, year and time from a locale-aware template, optional seconds.
- System Stats: a distinct color per measurement (download green, upload orange, disk
  read cyan, disk write pink, disk space yellow), CPU as a line or one block per core,
  disk space plus disk read/write rates.
- New tmux plugin with profiles (default: Claude, `claude`, resumed with
  `claude --continue`). Open a profile in a new tab or split from the Plugins menu
  (first profile: ⌥⌘T). The Session Manager saves tmux panes: after an app crash it
  reattaches to the still running session; after a restart it recreates the session with
  the resume command. Running sessions can be attached or ended from the manager.
- Protocol v1 additions (optional, backward compatible): manifest `position`
  ("leading"/"trailing") and widget `bars` (block graph, up to 64 values 0...1).
- Fix: Session Manager restores tabs again. Quitting no longer writes checkpoints while
  AppKit detaches tabs from their group, which saved tabs as separate windows.
- Sessions and Plugins menus are placed before Help; the session state is a small dot
  next to the Sessions button (details in its tooltip).

## 0.4.0 — 2026-10-14

- Replace the stretched native titlebar tabs with a compact Status Lab tab strip
  (`macos-titlebar-style = tabs`). Tabs keep a fixed comfortable width (max 220 pt),
  sit next to the window controls and use the terminal background color.
- The strip stays visible in native fullscreen, blending with the terminal.
- Hover shows a close button, otherwise the tab shortcut (⌘1…⌘9). Context menu:
  rename, tab color, close, close others, close to the right. A + button opens a tab.
- Native tab groups remain underneath: shortcuts, move-tab keybinds and session restore
  work as before. Dragging tabs to reorder or detach is not available in the strip.
- The Sessions button in the status bar no longer shows a focus ring and the separator
  sits directly next to the checkpoint status.

## 0.3.1 — 2026-10-14

- Replace the overflowing About buttons with centered, compact text links:
  Docs · Status Lab · Ghostty. Preserve descriptive tooltips and link semantics.
- Move the Sessions entry point into the status bar's trailing edge as a text
  button, next to the latest checkpoint status. The separate session strip above
  the bar is only shown when no status plugins are configured.
- Show Restart plugins as a text button, consistent with the other bar controls.

## 0.3.0 — 2026-10-14

- Reintegrate the existing Session Manager from the 2026-10-12 development task,
  previously omitted from the 0.1–0.2 Status Lab builds.
- Enable the v2 application identity and window-save-state for session checkpoints.
- Restore the Sessions menu and storage-status bar; autosave every five seconds.
- Restores layouts, directories and plain-text output into new shells, not running jobs.

## 0.2.1 — 2026-10-14

- About explicitly distinguishes Status Lab version/build/date from Ghostty's
  core version and upstream revision, and shows the plugin source base and local
  modifications. Source links no longer treat a Status Lab version as an upstream
  Ghostty release. Build metadata is derived during packaging.

## 0.2.0 — 2026-10-14

- Window and tab titles follow the active pane's reported working directory when
  status plugins are enabled. Explicit user tab-title overrides still take precedence.
- The status bar shows that pane's directory, with a full-path tooltip and home
  abbreviation. It keeps the last focused pane when focus moves to app controls.
- The local bundle removes the fixed app-title defaults from earlier test builds.
- Includes the 0.1.0 stability changes. Directory reporting depends on shell
  integration; unknown paths are shown as unavailable rather than fabricated.

## 0.1.0 — 2026-10-14

First explicitly versioned Status Lab release. Earlier test bundles were unversioned;
they are not retroactively labeled. The underlying Ghostty source remains
1.3.2-dev, base 7ec9e26 with status-plugin commit ae5c59a and local changes.

- Automatically retry failed plugins after 2, 4, 8, 16, 32, then 60 seconds.
  Continue at most once per minute; reset backoff after 60 seconds of healthy operation.
- Wait for the previous process to terminate before starting its replacement.
  Disabling/removing a host cancels pending retries. Healthy sibling plugins keep running.
- Preserve bounded output parsing, drain transient backlogs across polls, and allow
  a fresh heartbeat interval after a polling interruption.
- Record failure reason and retry delay in macOS unified logging, category StatusPlugins.
- Include manual Restart plugins and config-reload recovery from the previous patch.
- Clarify Reset Terminal Display in the context menu; it does not restart a shell.

Version policy: Status Lab uses MAJOR.MINOR.PATCH independently from Ghostty.
Patch: compatible fixes. Minor: new capabilities (and explicitly documented API changes
while below 1.0). Major: incompatible changes after 1.0. Protocol version remains 1.
Do not claim this is an upstream Ghostty release.
