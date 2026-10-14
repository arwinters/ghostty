import AppKit
import Darwin
import GhosttyKit

/// "Restart Terminal": replaces a pane — typically a hung one — with a fresh shell in the
/// same place, directory and font size, like iTerm2's Restart Session.
///
/// Closing a surface normally only sends SIGHUP to the shell's process group. A hung
/// foreground program runs in its own process group and may ignore SIGHUP, so it would
/// survive. Restart therefore signals every process attached to the pane's terminal device,
/// and force-kills whatever is still alive shortly after. Other panes and Ghostty itself
/// are never on that device. No undo entry is registered: undo would keep the old surface,
/// and with it the hung process, alive.
extension BaseTerminalController {
    func restartSurface(_ old: Ghostty.SurfaceView) {
        guard let app = ghostty.app, let surface = old.surface,
              let node = surfaceTree.root?.node(view: old) else { return }

        // tmux panes reattach to their session; the program inside keeps running.
        let tmux = TmuxPlugin.shared.pane(for: old.id)
        var config: Ghostty.SurfaceConfiguration
        if let tmux {
            config = TmuxPlugin.shared.surfaceConfiguration(for: tmux)
        } else {
            config = Ghostty.SurfaceConfiguration(from: ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT))
            // Start the default shell, not a one-off command or session replay wrapper.
            config.command = nil
            config.environmentVariables = [:]
            config.initialInput = nil
            config.waitAfterCommand = false
            if let pwd = old.pwd, pwd.hasPrefix("/") { config.workingDirectory = pwd }
        }

        let foreground = pid_t(truncatingIfNeeded: ghostty_surface_foreground_pid(surface))
        TerminalProcesses.terminate(sharingTerminalWith: foreground)

        let replacement = Ghostty.SurfaceView(app, baseConfig: config)
        if let tmux { TmuxPlugin.shared.register(replacement, as: tmux) }
        do {
            surfaceTree = try surfaceTree.replacing(node: node, with: .leaf(view: replacement))
        } catch {
            AppDelegate.logger.error("restart terminal failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        TmuxPlugin.shared.forget(old.id)
        Ghostty.moveFocus(to: replacement, from: old)
    }
}

/// Finds and stops the processes attached to one terminal device.
enum TerminalProcesses {
    /// SIGHUP (and SIGCONT, for stopped jobs) now, SIGKILL after a grace period for every
    /// process still attached to the same terminal. Runs the forced part off the main
    /// thread, because freeing the old surface waits for its shell to exit.
    static func terminate(sharingTerminalWith pid: pid_t, grace: TimeInterval = 0.8) {
        guard pid > 0, let device = terminalDevice(of: pid) else { return }
        let targets = processes(onTerminal: device)
        guard !targets.isEmpty else { return }
        for target in targets {
            kill(target, SIGHUP)
            kill(target, SIGCONT)
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + grace) {
            for target in processes(onTerminal: device) where targets.contains(target) {
                kill(target, SIGKILL)
            }
        }
    }

    static func terminalDevice(of pid: pid_t) -> UInt32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.e_tdev != UInt32.max, info.e_tdev != 0 else { return nil }
        return info.e_tdev
    }

    /// Processes whose controlling terminal is `device`, excluding Ghostty itself.
    static func processes(onTerminal device: UInt32) -> [pid_t] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_TTY, Int32(bitPattern: device)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0, size > 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        var processes = [kinfo_proc](repeating: kinfo_proc(), count: count + 8)
        size = processes.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &processes, &size, nil, 0) == 0 else { return [] }
        let own = getpid()
        return processes.prefix(size / MemoryLayout<kinfo_proc>.stride)
            .map(\.kp_proc.p_pid)
            .filter { $0 > 0 && $0 != own }
    }
}

extension Ghostty.SurfaceView {
    /// Context menu: restart this pane, asking first when a program is still running.
    @objc func restartTerminal(_ sender: Any?) {
        guard let controller = window?.windowController as? BaseTerminalController else { return }
        if needsConfirmQuit {
            let alert = NSAlert()
            alert.messageText = "Restart Terminal?"
            alert.informativeText = "All programs in this pane are stopped and a new shell starts in the same directory. Other panes are not affected."
            alert.addButton(withTitle: "Restart")
            alert.addButton(withTitle: "Cancel")
            alert.alertStyle = .warning
            guard let window else { return }
            alert.beginSheetModal(for: window) { [weak self, weak controller] response in
                guard response == .alertFirstButtonReturn, let self else { return }
                controller?.restartSurface(self)
            }
            return
        }
        controller.restartSurface(self)
    }
}
