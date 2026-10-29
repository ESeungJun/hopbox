<p align="center"><img src="docs/images/icon.png" width="120" alt="HOPBOX"></p>

<h1 align="center">HOPBOX · 택배상자</h1>

<p align="center">A little parcel box that hops between your full-screen spaces on macOS.<br>
Drop files, text and images in on one desktop, press the shortcut on another, and they're right there.</p>

<p align="center"><b>English</b> · <a href="README.ko.md">한국어</a></p>

<p align="center"><img src="docs/images/hero.png" width="560" alt="HOPBOX: the parcel box opened into a fan of files, a note and a screenshot"></p>

---

I work with a lot of full-screen apps spread across desktops.
Every time I wanted to attach a file or copy something from one space to another, the cursor hit the edge of the screen
and the drag simply stopped. So I'd leave full screen, rearrange windows, do the thing, and go back to full screen.

HOPBOX fixes that with a box you can call to whatever screen you're looking at.
Put things in, switch spaces, call it again, and take them out.

## How it works

1. Press **⇧⌘F** anywhere, even on top of a full-screen app. A parcel drops in next to your cursor.
2. **Drop** files onto the box, or press **⌘V** to put in whatever you copied: text, images, files.
3. Switch to another space and press **⇧⌘F** again. The same box arrives there.
4. Click the box to open it. Its contents fan out like a Dock stack.
   **Drag** an item out to attach it, or **click** it to copy.

## Features

- **Feels like a delivery** — the box drops in, lands with a squash and a little dust, and opens itself if there's something inside.
  It wobbles when you drag something over it and bounces with a "+1" when you drop.
- **Stays out of full screen's way** — it floats over full-screen apps without stealing focus or pulling you out of the space.
- **Safe to drag out** — items always leave as copies. Dragging a file into Finder never moves your original.
- **Fan, then list** — up to ten items fan out; "N more" opens a full list you can drag everything out of at once.
- **Screenshots go straight in** — new screenshots and screen recordings are added automatically,
  following the save location you set in macOS.
- **Copied images go straight in** — images copied in Slack or a browser, and clipboard screenshots (⌃⇧⌘4), are added too.
  Files copied in Finder, cells from spreadsheets and password-manager values are left alone.
- **Undo** — removing items or emptying the box can be undone for five seconds.
- **Remembers** — the box keeps its contents across restarts. Files are referenced, not copied.

Both automatic options, launch at login and the shortcut itself can be changed from the menu bar icon.

## Install

### Download

Grab the installer for your Mac from [Releases](https://github.com/ESeungJun/hopbox/releases/latest).

| Mac | File |
|---|---|
| Apple silicon (M1 and later) | `Hopbox-<version>-macOS-apple-silicon.dmg` |
| Intel | `Hopbox-<version>-macOS-intel.dmg` |

You can check which one you have under  menu → About This Mac ("Chip" or "Processor").

Open the dmg and drag `택배상자.app` into Applications.
It's signed with a Developer ID and notarized by Apple, so it opens without any warning.

Requires macOS 13 or later. No permissions are needed: the global shortcut doesn't require Accessibility access.

### Build from source

You only need the Xcode Command Line Tools (`xcode-select --install`), not Xcode itself.

```bash
git clone https://github.com/ESeungJun/hopbox.git
cd hopbox
./build.sh install      # builds 택배상자.app, installs it to ~/Applications and opens it
```

## Built with

- **Swift · SwiftUI · AppKit** — a native menu bar app with a non-activating panel that can sit on full-screen spaces.
- **Carbon hot keys** — a global shortcut without extra permissions.
- **QuickLook Thumbnailing** — Finder-style previews of what's in the box.

Built together with Claude Code.

## Development

```bash
swift build             # debug build
./build.sh              # build/택배상자.app
./build.sh install      # install to ~/Applications and launch
./build.sh release      # dmgs for Apple silicon and Intel (build/release)
                        # set SIGN_IDENTITY and NOTARY_PROFILE to sign and notarize
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

Contents are stored in `~/Library/Application Support/Hopbox`.

</details>
