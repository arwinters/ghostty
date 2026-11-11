# Status Lab changelog

## 0.9.3 — 2026-11-11

- Tabs in the tab strip can be dragged to a new position; the tabs they pass make room.
  Move Tab Left and Move Tab Right are in the tab's menu.
- A missing AI tool installs from the menu (Install Codex…) or the Plugin Manager. The
  install window shows what Homebrew will install (version, description, website,
  download size, where it is linked), then the steps Prepare › Download › Install ›
  Link › Ready with a measured download (size, percentage, speed) and Homebrew's own
  output. Afterwards the tool opens straight away.
- `macos-ai-session` takes an optional `install:` command; Claude Code, Codex, Gemini CLI
  and Aider install with Homebrew by default.

## 0.9.2 — 2026-11-11

- AI sessions: right-click a pane › New AI Session › Claude Code, Codex or any configured
  tool › Split Right, Split Down or New Tab. Starts in the pane's directory, in a tmux
  session (keeps running when Ghostty quits; resumes after a restart). Also in the
  Plugins menu.
- New configuration option `macos-ai-session` (repeatable;
  `name:…,command:…,resume:…`). Existing Status Lab configurations get Claude Code and
  Codex entries once; remove them to drop the menu. Tools that are not installed are
  shown disabled.
- Plugin Manager: AI Sessions page with the configured tools, their install state and
  configuration errors, and buttons to open and reload the configuration.
- The pane menu no longer shows AutoFill and Services entries (such as OpenPGP), which do
  not apply to a terminal.
- Status Lab now lives in `macos/StatusLab` (was `examples/status-plugins`), so the
  repository keeps Ghostty's own layout. The README describes the features briefly;
  PLUGINS.md covers writing and sharing plugins. The default configuration is
  `status-lab.config`.

## 0.9.1 — 2026-11-11

- tmux runs on its own: when no tmux server is running, Ghostty starts it as a launchd
  job of the user (`tmux -D`, in the login environment) instead of from a pane. Quitting,
  a crash or a Force Quit of Ghostty only detaches; sessions and programs such as Claude
  keep running and can be attached from any terminal.
- Quitting no longer asks for confirmation when only tmux panes are busy, so Ghostty
  quits instead of waiting in the Dock.
- tmux history is saved: the visible screen with regular checkpoints, the last 3000
  lines when quitting and before sleep. A session that ended with a restart comes back
  with that history above the resume command instead of an empty pane.
- Copy Attach Command in the pane's tmux menu and in the Plugin Manager.

## 0.9.0 — 2026-11-11

- Based on the latest Ghostty `main` (709 upstream commits since 0.8.4); Zig 0.17.
- Plugin Manager:
  - An **Installed** page lists every plugin with its kind (built-in, installed package or
    executable), version and live state (running, starting, off, error, waiting for
    Apply), with a switch per plugin and the number of status bar slots in use.
  - Every plugin, built-in or added, has its own page with a header (description,
    version, author, website, state, switch). "Community Plugins" is gone: added plugins
    are listed with the built-in ones.
  - Plugin packages: a folder with `plugin.json` and an executable. **Install Plugin…**
    validates it and copies it into the app; reinstalling updates it, uninstalling
    removes the copy. Example: `packages/battery`.
  - Unapplied changes are highlighted in the footer.
- Session Manager:
  - Workspaces: the open windows always belong to a workspace, which saves itself; one
    is created when none exists. Opening a workspace saves and closes the open windows
    first; tmux sessions keep running. New Workspace, Save as New Workspace, earlier
    versions per workspace, and a selection mode to delete several at once.
  - Restores the right session after a restart: a tmux pane where Claude Code had
    exited no longer comes back running `claude --continue`; one odd directory or long
    output can no longer make every newer checkpoint fail.
  - Far less work in the background: no scrollback reads every 5 seconds (up to 50 MB
    per pane before), no re-reading every stored session after each save.
- One shared set of plugin processes for all windows (before: one per tab), and the bar
  redraws only when a value changes. tmux is polled every 5 seconds, only while
  Ghostty is active.
- Right-click menu in every pane, also inside tmux mouse mode: clipboard, tabs and
  splits, the pane's directory, tmux, workspaces and terminal actions.

## 0.8.4 — 2026-10-14

- Fullscreen: the tab strip moves into a titlebar accessory, so it is hidden and appears
  with the menu bar when the pointer reaches the top, also with a single tab (the native
  tab bar only appears with two or more tabs).
- Weather shows a real, larger weather icon (SF Symbols, multicolor) instead of a tiny
  text glyph, with day and night variants.
- Protocol addition (optional): widget `symbol`, an SF Symbol name drawn before the value.

## 0.8.3 — 2026-10-14

- Fix (regression from 0.4.0): in native fullscreen the tab strip stayed visible and the
  revealed macOS titlebar slid over the terminal text transparently. In fullscreen the
  strip now steps aside and the native tab bar returns, so tabs are hidden and appear
  with the menu bar when the pointer reaches the top. The revealed titlebar uses the
  terminal background again. Outside fullscreen nothing changes.

## 0.8.2 — 2026-10-14

- Tab titles of tmux panes show the session's directory (from tmux) instead of the bare
  default title. One `tmux list-panes` call every 2 seconds serves tab titles and the
  status bar, only while tmux panes exist.
- Code review fixes:
  - tmux panes work for fish users: the attach-or-create script always runs in /bin/sh;
    the login shell only provides the environment.
  - `window-save-state = never` is migrated to `always` once, so users can turn session
    restore off again.
  - Duplicate community plugin ids no longer make the host reject the whole manifest;
    new plugins get unique ids. The editor no longer crashes on Remove and accepts spaces
    in Arguments.
  - tmux calls time out after one second, so a wedged tmux server cannot freeze the
    pane context menu.
  - Only the 10 newest Before Launch recovery points are kept, and replay files with
    saved terminal output are deleted at the next launch.
  - Restart Terminal leaves the pane untouched if replacing it fails, and keeps the font
    size of tmux panes.
  - build.py explains a missing `zig-out/share` when using --skip-core.
- Documentation: status-lab/README.md describes why Status Lab exists, what it contains,
  the design choices, how it was tested and its known limitations.

## 0.8.1 — 2026-10-14

- Closing a tab or window with more than one pane always asks first, even when nothing
  is running (Ghostty's confirm-close-surface only covers running programs). Covers the
  tab strip's close button, Close Tab, the close_tab keybinding and the window's close
  button. "Don't ask again" turns it off.
- Session Manager is enabled in every Status Lab build (StatusLabVersion), not only for
  specific bundle identifiers; settings and sessions live under the app's own bundle id.
- examples/status-plugins/status-lab/build.py builds the app from this branch.

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
