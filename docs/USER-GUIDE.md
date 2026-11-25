# Triptych user guide (for testers)

Triptych puts Windows, Mac and Linux in one iPhone/iPad app. This is the **0.1.0 preview** ([Releases](https://github.com/RageMC/triptych/releases)): parts of it do not work yet (see [What is not working yet](#what-is-not-working-yet)). Please read that section before you report a bug.

Triptych includes no Windows, macOS or other copyrighted software. You bring your own.

## What you need

- An iPad or iPhone with an M1/A14 chip or newer (iPadOS/iOS 26 or 27).
- [LiveContainer](https://github.com/LiveContainer/LiveContainer) installed, with a way to give apps JIT (its own "Launch with JIT", or StikDebug with a pairing file).
- For Windows 11: your own Windows 11 **ARM64** ISO.
- For Mac apps: your own Mac apps (for example a CrossOver zip you already own).
- Plenty of free storage. A Windows PC disk is 64 GB (sparse, it grows as used); macOS needs about 43 GB.

## Install and turn on JIT

1. In LiveContainer, add the Triptych `.ipa` (the app list's **+** button).
2. Open the app's settings in LiveContainer and turn on **Launch with JIT**.
3. Launch Triptych from LiveContainer.
4. In Triptych, open **Easel** (top left, "Setup for JIT, storage & images"). It shows **JIT status** and walks you through pairing if JIT is off.

Linux (Fresco) works without JIT. Windows and Mac systems need it.

## The home screen

Home is the triptych: **Windows** (blue), **Mac** (violet), **Linux** (amber). Tap a system to open it. Names:

| Name | What it is |
|---|---|
| **Casement** | A full Windows 11 PC (virtual machine) |
| **Pane** | Windows games and apps |
| **Atelier** | macOS and Mac apps |
| **Fresco** | Linux |
| **Easel** | Setup: JIT, storage, your images |
| **Provenance** | Log export |
| **Curator** | On-device diagnostics: explains failures, offers fixes, files reports |

## Casement: Windows 11 PC

A virtual ARM64 PC with UEFI firmware, TPM 2.0, an NVMe disk, USB and a screen.

- **You need:** your own Windows 11 ARM64 ISO and JIT on. Pick the ISO in Easel (**Casement · Windows 11 ARM64 ISO**) or on the Casement page.
- **Settings:** memory and CPUs (Windows 11 Setup needs at least 4 GB and 2 CPUs). Tap **Start**; **Stop** shuts it down and you can start again.
- If the screen says "Press any key to boot from CD or DVD", tap the **Press a key** button.

### Key bar and touch

A key bar sits under the screen (scroll it sideways). It has what a touch keyboard lacks: **Esc, Tab, arrows, Enter, Backspace, Del, Space, Home, End, PgUp, PgDn, F1-F12**, **Ctrl+Alt+Del**, and **Ctrl, Shift, Alt, Win**. The modifier keys latch: tap **Ctrl**, then tap a key to send Ctrl+key. A latched modifier is released after one key (or tap it again). Use the keyboard button to show or hide the system keyboard. Hardware keyboards work too.

| Touch | Does |
|---|---|
| Tap | Left click |
| Long press | Right click |
| Two-finger drag | Scroll |

## Pane: Windows games and apps

Runs Windows games and apps through translation (Wine and FEX), with Steam, GOG, Epic and itch.io stores inside it. Needs JIT. **It has never run on a real device yet.** Open it first after launching Triptych (see sharing, below).

## Atelier: macOS and Mac apps

- **macOS VM:** downloads Apple's restore image (about 43 GB free needed) and installs a Mac. Needs JIT and a recent chip.
- **Mac apps:** import your own Mac apps (for example a CrossOver zip). The Mac apps page lists them.
- Atelier's export tools save to Files under `Exports/`.

## Fresco: Linux

Runs without JIT. Open **Linux** and tap **Start** for a terminal. Under **Manage Linux Distributions** download Alpine, Ubuntu, Debian, Fedora or Arch Linux ARM, or import your own `.tar.zst` root filesystem. The **Desktop** tab can run Xfce (software rendering, so slow). An **x86 PC** page boots x86-64 ISOs (such as Linux) on QEMU; supply your own ISO in Easel.

## Which systems share a launch (and the one-tap restart)

Some systems cannot live in the same run of the app. These pairs can run together:

- Casement + Mac apps
- Fresco + Casement
- Fresco + Mac apps
- Fresco + x86 PC

Opening any other combination shows **Restart Triptych into …**. Tap it: Triptych quits, asks LiveContainer (or StikDebug) to start it again (with JIT if **Launch with JIT** is on), and opens the system you picked. **Unsaved work in the running system is lost.** If nothing relaunches, tap Triptych's icon in LiveContainer; it still opens the system you chose.

## Export logs (Provenance)

When something goes wrong, tap **Export logs** (Home → Help, About, Settings, and the toolbar of each system page). It zips the logs from this run and the one before, plus device, iOS, build and JIT details, and opens the share sheet. Send that zip with your report, and say what you tapped and what you expected.

## Curator

Open **Curator** from Home (Help & Credits) or the stethoscope button on any system page, then tap **Check my logs**.
It reads this run's and the previous run's logs. Known failures (for example JIT off, no boot disk, a Windows driver
that fails to load) come with an explanation and, where possible, an **Apply fix** button. For anything else, an
on-device model (Apple Intelligence on iOS 26+, or the optional Qwen3-0.6B download in Easel) writes a short summary
and suggests one fix. Nothing leaves the device unless you tap **Report**: it shows the exact issue text and the
scrubbed log attachment, then files it to [RageMC/triptych-issues](https://github.com/RageMC/triptych-issues) after
you sign in with GitHub, or anonymously without an account (through Triptych's relay).

## What is not working yet

From the project status file. Expect these.

- **Not yet confirmed on a device:** JIT claim fixes, one-tap restart through LiveContainer, and stopping and restarting a system in place on a device.
- **Casement (Windows 11):** on a real iPad the installer reached Windows' kernel, which crashed (stop code 0xC000007B). Another run stopped in the firmware ("Synchronous Exception"). Installing Windows 11 to the desktop on iOS has **not** worked yet. On a Mac it has.
- **Pane (Windows games):** built but never run on a device. Memory use and the fixed address range it needs are untested. Some of its extra layers are not done.
- **Atelier:** booting and installing macOS, and running Mac apps, are untested on a device. The Mac VM uses all the JIT memory, so it cannot share a launch with other systems. Chromium/Electron Mac apps are a hard case and may not work.
- **Fresco:** the Xfce install path is only partly tested; GNOME, KDE and Cinnamon, graphics acceleration and x86 programs via FEX are not there yet. The non-terminal console has a fixed 80x40 size.
- **Android:** no runtime in the app.
- **Speed:** nobody has measured performance on a device. Expect slow.
- The app has not had its final full code review, and is not the finished product.
