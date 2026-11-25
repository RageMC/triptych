// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import SwiftUI

/// Installs and starts Xfce inside the running Linux guest (commands typed into its console).
/// Xvfb keeps the screen in /dev/shm/Xvfb_screen0, which LinuxDesktopView maps from the
/// rootfs on the host; guest_input_agent.py (bundled) takes touch/keyboard over 127.0.0.1:5950.
/// Design: engines/linux-desktop/DESIGN.md.
@MainActor
final class LinuxDesktop: ObservableObject {
    static let shared = LinuxDesktop()
    static let port: UInt16 = 5950
    @Published var started = false

    /// Package manager of a rootfs, from what is on disk.
    static func family(_ root: URL) -> String? {
        let fm = FileManager.default
        for (tool, fam) in [("usr/bin/apt-get", "apt"), ("sbin/apk", "apk"), ("usr/bin/pacman", "pacman"), ("usr/bin/dnf", "dnf"), ("usr/bin/dnf5", "dnf")]
        where fm.fileExists(atPath: root.appendingPathComponent("data/" + tool).path) { return fam }
        return nil
    }

    static func isInstalled(_ root: URL) -> Bool {
        let fm = FileManager.default
        return ["usr/bin/Xvfb", "usr/bin/xfce4-session", "usr/bin/python3"].allSatisfy {
            fm.fileExists(atPath: root.appendingPathComponent("data/" + $0).path)
        }
    }

    /// Xfce, Xvfb, D-Bus and what the input agent needs (python3 + libXtst). Only the apt line has been run (Ubuntu 26.04).
    static func installCommand(_ root: URL) -> String? {
        // The fake rootfs ships an empty /etc/resolv.conf; without a nameserver apt finds no package lists.
        let dns = "[ -s /etc/resolv.conf ] || echo 'nameserver 1.1.1.1' > /etc/resolv.conf; "
        return installLine(root).map { dns + $0 }
    }

    private static func installLine(_ root: URL) -> String? {
        switch family(root) {
        case "apt": return "export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y xfce4 xfce4-terminal dbus-x11 xvfb python3 libxtst6 poppler-data- && echo XFCE-INSTALLED"
        case "apk": return "apk add xfce4 xfce4-terminal dbus dbus-x11 xvfb python3 libxtst font-dejavu && echo XFCE-INSTALLED"
        case "pacman": return "pacman -Sy --noconfirm xfce4 xorg-server-xvfb python libxtst dbus && echo XFCE-INSTALLED"
        case "dnf": return "dnf install -y xfce4-panel xfce4-session xfwm4 xfdesktop xfce4-terminal dbus-x11 xorg-x11-server-Xvfb python3 libXtst dejavu-sans-fonts && echo XFCE-INSTALLED"
        default: return nil
        }
    }

    func install(_ root: URL) {
        guard let cmd = Self.installCommand(root) else { return }
        LinuxSession.shared.send(ArraySlice(Array((cmd + "\n").utf8)))
    }

    /// When Start was tapped: framebuffer files made before this are stale (another session's).
    private(set) var startedAt = Date.distantFuture

    /// The guest sees /opt/triptych and /etc/resolv.conf (read-only) from this host folder,
    /// mounted by the engine at boot (LinuxRunner's ISH_BIND_MOUNTS).
    nonisolated static func prepareGuestTools() -> String? {
        let fm = FileManager.default
        let dir = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Linux/guest-tools", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        var mounts: [String] = []
        if let agent = Bundle.main.url(forResource: "guest_input_agent", withExtension: "py") {
            let dst = dir.appendingPathComponent("input-agent.py")
            try? fm.removeItem(at: dst)
            if (try? fm.copyItem(at: agent, to: dst)) != nil,
               (try? startScript.write(to: dir.appendingPathComponent("triptych-desktop"), atomically: true, encoding: .utf8)) != nil {
                mounts.append("/opt/triptych=\(dir.path):ro")
            }
        }
        let resolv = dir.appendingPathComponent("resolv.conf")
        if tp_write_host_resolv_conf(resolv.path) == 0 ||
            (try? "nameserver 1.1.1.1\nnameserver 8.8.8.8\n".write(to: resolv, atomically: true, encoding: .utf8)) != nil {
            mounts.append("/etc/resolv.conf=\(resolv.path):ro")
        }
        return mounts.isEmpty ? nil : mounts.joined(separator: ",")
    }

    func start(width: Int, height: Int) {
        startedAt = Date()
        started = true
        let cmd = "sh /opt/triptych/triptych-desktop \(width) \(height) >/tmp/triptych-desktop.log 2>&1 &\n"
        LinuxSession.shared.send(ArraySlice(Array(cmd.utf8)))
    }

    /// Guest side. Compositing off (llvmpipe only), Xvfb's framebuffer file in /dev/shm.
    nonisolated static let startScript = #"""
    #!/bin/sh
    # Triptych: Xfce on Xvfb, screen in /dev/shm/Xvfb_screen0, input agent on 127.0.0.1:5950.
    W=${1:-1280}; H=${2:-720}
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export HOME=/root DISPLAY=:0 XDG_RUNTIME_DIR=/tmp/runtime-root TRIPTYCH_INPUT_PORT=5950
    mkdir -p /tmp/runtime-root /tmp/.X11-unix "$HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
    chmod 700 /tmp/runtime-root
    chmod 1777 /tmp/.X11-unix
    X="$HOME/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml"
    [ -f "$X" ] || printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<channel name="xfwm4" version="1.0"><property name="general" type="empty"><property name="use_compositing" type="bool" value="false"/></property></channel>' > "$X"
    rm -f /tmp/.X0-lock /tmp/.X11-unix/X0 /dev/shm/Xvfb_screen0
    Xvfb :0 -screen 0 "${W}x${H}x24" -fbdir /dev/shm -nolisten tcp >/tmp/xvfb.log 2>&1 &
    i=0
    while [ $i -lt 150 ] && ! [ -S /tmp/.X11-unix/X0 ]; do sleep 0.2; i=$((i+1)); done
    dbus-run-session -- xfce4-session >/tmp/xfce-session.log 2>&1 &
    python3 /opt/triptych/input-agent.py >/tmp/input-agent.log 2>&1 &
    wait

    """#
}

/// The Desktop tab of the Linux page: install/start Xfce, then the desktop itself.
struct LinuxDesktopPane: View {
    let root: URL
    @ObservedObject private var d = LinuxDesktop.shared
    @Binding var mode: LinuxView.Mode
    let windowSize: CGSize?

    var body: some View {
        if d.started {
            LinuxDesktopView(rootfsURL: root, notBefore: d.startedAt)
        } else {
            GeometryReader { geo in
                ZStack {
                    TriptychBackdrop()
                    VStack(spacing: 14) {
                        TriptychPanelCard(accent: TriptychPalette.linuxLight, raised: true) {
                            VStack(spacing: 12) {
                                Image(systemName: "macwindow.on.rectangle")
                                    .font(.system(size: 38, weight: .semibold))
                                    .foregroundStyle(TriptychPalette.linuxLight)
                                if LinuxDesktop.isInstalled(root) {
                                    Text("Xfce is installed. Start it to see the desktop here.")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                    Button("Start Xfce") {
                                        let size = GuestDisplaySize(windowSize ?? geo.size, scale: 1,
                                                                    longestEdge: 1280, minimumShortEdge: 640)
                                        d.start(width: size.width, height: size.height)
                                    }
                                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .linux))
                                    .accessibilityIdentifier("linux-desktop-start")
                                } else if LinuxDesktop.installCommand(root) != nil {
                                    Text("Xfce is not installed in this system. Installing downloads about 250 packages and takes a while on the interpreter; progress shows in the terminal.")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                    Button("Install Xfce") {
                                        LinuxDesktop.shared.install(root)
                                        mode = .terminal
                                    }
                                    .buttonStyle(TriptychPrimaryButtonStyle(panel: .linux))
                                    .accessibilityIdentifier("linux-desktop-install")
                                } else {
                                    Text("Desktops need a system with apt, apk, dnf or pacman. Pick Ubuntu with the stack button.")
                                        .font(.system(size: 14))
                                        .foregroundStyle(TriptychPalette.textSecondary)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 16)
                    .triptychColumn()
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }
}
