<p align="center"><img src="docs/images/icon.png" width="120" alt="HOPBOX"></p>

<h1 align="center">HOPBOX · 택배상자</h1>

<p align="center">A little parcel box that hops between your full-screen spaces and desktops on macOS and Windows.<br>
Drop files, text and images in on one desktop, press the shortcut on another, and they're right there.</p>

<p align="center"><b>English</b> · <a href="README.ko.md">한국어</a></p>

<p align="center">
  <a href="https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-macOS-apple-silicon.dmg"><b>⬇ Download for Mac (Apple silicon)</b></a> ·
  <a href="https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-macOS-intel.dmg"><b>⬇ Download for Mac (Intel)</b></a><br>
  <a href="https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-Windows-x64-Setup.exe"><b>⬇ Download for Windows (x64)</b></a> ·
  <a href="https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-Windows-arm64-Setup.exe"><b>⬇ Download for Windows (ARM)</b></a><br>
  <sub>Mac: signed and notarized, macOS 13+ · Windows 10+ · <a href="https://github.com/ESeungJun/hopbox/releases">All releases</a></sub>
</p>

<p align="center"><img src="docs/images/hero.png" width="560" alt="HOPBOX: the parcel box opened into a fan of files, a note and a screenshot"></p>

---

I work with a lot of full-screen apps spread across desktops.
Every time I wanted to attach a file or copy something from one space to another, the cursor hit the edge of the screen
and the drag simply stopped. So I'd leave full screen, rearrange windows, do the thing, and go back to full screen.

HOPBOX fixes that with a box you can call to whatever screen you're looking at.
Put things in, switch spaces, call it again, and take them out.

## How it works

1. Press **⌃⌥B** (**Ctrl+Alt+B** on Windows) anywhere, even on top of a full-screen app. A parcel drops in next to your cursor.
2. **Drop** files onto the box, or press **⌘V** (**Ctrl+V**) to put in whatever you copied: text, images, files.
3. Switch to another space or desktop and press the shortcut again. The same box arrives there.
4. Click the box to open it. Its contents fan out like a Dock stack.
   **Drag** an item out to attach it, or **click** it to copy.

## Features

- **Feels like a delivery** — the box drops in, lands with a squash and a little dust, and opens itself if there's something inside.
  It wobbles when you drag something over it and bounces with a "+1" when you drop.
- **Stays out of full screen's way** — it floats over full-screen apps without stealing focus or pulling you out of the space.
- **Safe to drag out** — items always leave as copies. Dragging a file into Finder never moves your original.
- **Fan, then list** — up to ten items fan out; "N more" opens a full list you can drag everything out of at once.
- **Screenshots go straight in** — new screenshots and screen recordings are added automatically,
  following the save location you set in macOS, or the Pictures\Screenshots and Videos\Screen Recordings·Captures folders on Windows.
- **Copied images go straight in** — images copied in Slack or a browser, and clipboard screenshots (⌃⇧⌘4 on Mac, Win+Shift+S on Windows), are added too.
  Files copied in Finder or Explorer, cells from spreadsheets and password-manager values are left alone.
- **Undo** — removing items or emptying the box can be undone for five seconds.
- **Remembers** — the box keeps its contents across restarts. Files are referenced, not copied.
- **Keeps itself up to date** — checks for a new release at launch and once a day, then installs it and relaunches when you click.
  On Mac it only installs an update signed with the same Developer ID and notarized by Apple; on Windows the installer must match the SHA-256 that GitHub publishes.
  The current version is shown in the menu.

Both automatic options, launch at login and the shortcut itself can be changed from the box icon in the menu bar (the notification area on Windows).
A global shortcut keeps the keys from reaching other apps, so the box only accepts combinations that rarely clash:
⌃ plus ⌥, ⇧ or ⌘ on Mac, and two of Ctrl, Alt and Win on Windows.
macOS shortcuts are refused too. On Windows, combinations already taken by Windows or another app's global shortcut are refused.
macOS doesn't reveal other apps' global shortcuts, so if one clashes on Mac, pick a different combination for the box.

## Install

### Mac

Grab the installer for your Mac from [Releases](https://github.com/ESeungJun/hopbox/releases/latest).

| Mac | File |
|---|---|
| Apple silicon (M1 and later) | [`Hopbox-macOS-apple-silicon.dmg`](https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-macOS-apple-silicon.dmg) |
| Intel | [`Hopbox-macOS-intel.dmg`](https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-macOS-intel.dmg) |

You can check which one you have under  menu → About This Mac ("Chip" or "Processor").

Open the dmg and drag `택배상자.app` into Applications.
It's signed with a Developer ID and notarized by Apple, so it opens without any warning.

Requires macOS 13 or later. No permissions are needed: the global shortcut doesn't require Accessibility access.

### Windows

| PC | Installer |
|---|---|
| Most PCs (Intel, AMD) | [`Hopbox-Windows-x64-Setup.exe`](https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-Windows-x64-Setup.exe) |
| ARM PCs (Snapdragon and others) | [`Hopbox-Windows-arm64-Setup.exe`](https://github.com/ESeungJun/hopbox/releases/latest/download/Hopbox-Windows-arm64-Setup.exe) |

The installer installs for your account only, without admin rights, and puts a box icon in the notification area.
The app isn't code-signed yet, so SmartScreen may warn you on first launch: click **More info → Run anyway**.

Requires Windows 10 or later. The box shows up on every virtual desktop and over full-screen windows.

Uninstalling keeps your box contents and kept files in `%APPDATA%\Hopbox`. Delete that folder if you don't need them.

### Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`), not Xcode itself.

```bash
git clone https://github.com/ESeungJun/hopbox.git
cd hopbox
./build.sh install      # builds 택배상자.app, installs it to ~/Applications and opens it
```

## Built with

- **Mac: Swift · SwiftUI · AppKit** — a native menu bar app with a non-activating panel that can sit on full-screen spaces.
  - **Carbon hot keys** — a global shortcut without extra permissions.
  - **QuickLook Thumbnailing** — Finder-style previews of what's in the box.
- **Windows: C# · WPF (.NET 8)** — a tool window that stays out of the taskbar, plus a notification-area icon.
  - **RegisterHotKey** for the global shortcut, **AddClipboardFormatListener** for clipboard changes.
  - **Shell thumbnails** — Explorer-style previews.

Built together with Claude Code.

## Development

```bash
swift build             # debug build
./build.sh              # build/택배상자.app
./build.sh install      # install to ~/Applications and launch
./build.sh release      # dmgs for Apple silicon and Intel (build/release)
                        # set SIGN_IDENTITY and NOTARY_PROFILE to sign and notarize
```

The Windows app builds with the .NET 8 SDK. Installers are built by GitHub Actions (`.github/workflows/windows.yml`).

```powershell
dotnet test windows/Hopbox.Windows.Tests      # tests
dotnet run --project windows/Hopbox.Windows   # run
```

<details>
<summary>Project layout</summary>

| Path | Role |
|---|---|
| `Sources/Hopbox/AppDelegate.swift` | Menu bar item, global shortcut, settings |
| `Sources/Hopbox/ShelfPanel.swift` | The floating panel: delivery animation, open/close, keyboard, drop target |
| `Sources/Hopbox/BoxLayout.swift` | Window size and icon position for each state, so the box never jumps |
| `Sources/Hopbox/BoxView.swift` | The box icon and its animations, toasts |
| `Sources/Hopbox/FanView.swift` | Dock-stack style fan of items |
| `Sources/Hopbox/ShelfView.swift` | Full list view |
| `Sources/Hopbox/ShelfStore.swift` | What's in the box: adding, copying, removing with undo, saving |
| `Sources/Hopbox/ScreenCaptureWatcher.swift` | Auto-adding screenshots, screen recordings and copied images |
| `Sources/Hopbox/Shortcut.swift` | The shortcut: saved value, display name, recorder window |
| `Sources/Hopbox/DragSource.swift` | Copy-only drag out, click vs. drag handling |
| `Sources/Hopbox/Thumbnails.swift` | QuickLook previews |
| `Sources/Hopbox/Log.swift` | Logs which pasteboard types came and went (never the contents) |
| `Sources/Hopbox/Updater.swift` | Checks GitHub releases, verifies the signature and notarization, swaps the app and relaunches |
| `windows/Hopbox.Windows/` | Windows app: notification area (`Tray`), shortcut (`HotKey`, `ShortcutWindow`), box window (`BoxWindow`, `FanView`, `ListCard`), contents (`ShelfStore`), clipboard in and out (`Transfer`), auto-adding (`Watchers`), updates (`Updater`) |
| `windows/Hopbox.Windows.Tests/` | Windows tests |
| `windows/installer/hopbox.iss` | Windows installer (Inno Setup) |

Contents are stored in `~/Library/Application Support/Hopbox` on Mac and `%APPDATA%\Hopbox` on Windows.

</details>
