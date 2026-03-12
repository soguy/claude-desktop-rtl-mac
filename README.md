# Claude Desktop RTL Patch for macOS

Adds automatic right-to-left (RTL) text support to [Claude Desktop](https://claude.ai/download) on macOS. Hebrew and Arabic text is detected in real-time and aligned properly — both in the chat input and in Claude's responses — while code blocks stay left-to-right.

> **Based on [claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch) by [@shraga100](https://github.com/shraga100)**, which provides the same functionality for Windows. The RTL detection JavaScript is from that project; this repository adapts the patching mechanism for macOS (different app structure, Electron fuses, code signing).

## What it does

- **Chat input**: automatically switches to RTL alignment when you type Hebrew/Arabic
- **Claude's responses**: detects RTL text in real-time as responses stream in
- **Code blocks**: always stay LTR — code formatting is never affected
- **Mixed content**: smart 3-layer detection handles sentences mixing Hebrew/Arabic and English
- **Non-destructive**: creates a patched *copy* of Claude.app — the original is never modified
- **Distinct icon**: the patched app has an "RTL" badge on its icon so you can tell them apart at a glance

## Before & After

| Without patch | With patch |
|:---:|:---:|
| Hebrew/Arabic text left-aligned, hard to read | Hebrew/Arabic text properly right-aligned |
| `שלום עולם` / `مرحبا بالعالم` stuck to the left | `שלום עולם` / `مرحبا بالعالم` aligned to the right |

## Requirements

- **macOS** (tested on macOS 15 Sequoia / macOS 26 Tahoe)
- **Claude Desktop** installed at `/Applications/Claude.app`
- **Node.js** (v16+) — needed for `npx` which runs `@electron/asar` and `@electron/fuses`
  - Install via [nodejs.org](https://nodejs.org/) or `brew install node`

## Quick Start

```bash
# Clone the repo
git clone https://github.com/soguy/claude-desktop-rtl-mac.git
cd claude-desktop-rtl-mac

# Install the patch
./patch.sh --install
```

> **Downloaded the ZIP instead of cloning?** You may need to make the script executable first: `chmod +x patch.sh`

That's it. A patched copy is created at `~/Applications/Claude-RTL.app` (your home folder, not `/Applications/`) and launches automatically.

## Usage

```bash
# Install (or update after Claude updates)
./patch.sh --install

# Remove the patched copy
./patch.sh --uninstall

# Check status
./patch.sh --status

# Interactive menu
./patch.sh

# Show help
./patch.sh --help
```

## How it works

The patcher performs these steps:

1. **Copies** `/Applications/Claude.app` → `~/Applications/Claude-RTL.app`
2. **Extracts** the Electron `app.asar` archive
3. **Prepends** the RTL detection JavaScript into `.vite/build/*.js` renderer files
4. **Repacks** the `app.asar` archive
5. **Disables** the `EnableEmbeddedAsarIntegrityValidation` Electron fuse — this is required because the modified archive has a different hash, and Electron would crash on startup without this step
6. **Re-signs** the app with an ad-hoc code signature

The original `/Applications/Claude.app` is **never touched**.

### Why a copy instead of patching in-place?

Unlike the [Windows version](https://github.com/shraga100/claude-desktop-rtl-patch) which patches the original installation directly, the macOS version creates a separate copy. This is safer because:

- **No sudo required** — `~/Applications/` is user-writable, so the script never needs elevated privileges
- **Original stays intact** — `/Applications/Claude.app` is never touched; you can always fall back to it
- **Auto-updates keep working** — Anthropic's updates go to the original app and won't conflict with the patch
- **No risk of breaking Claude** — if anything goes wrong, just delete the patched copy and the original is still there
- **macOS protections respected** — `/Applications/Claude.app` is owned by root and protected by App Management permissions; modifying it would require sudo and bypassing macOS security features

## After Claude updates

When Claude Desktop auto-updates, it updates the original at `/Applications/Claude.app`. Your patched copy at `~/Applications/Claude-RTL.app` is a separate, independent app — it won't receive auto-updates. After Claude updates, re-run the patcher to create a fresh patched copy from the new version:

```bash
./patch.sh --install
```

This creates a fresh patched copy from the updated original.

**Tip:** Keep the original `Claude.app` around for updates. Let it update itself normally, then re-run the patcher. The patched copy may show update prompts, but updates won't apply correctly to it — always update via the original app.

## Uninstalling

```bash
./patch.sh --uninstall
```

This removes `~/Applications/Claude-RTL.app`. The original Claude.app is unaffected.

## Troubleshooting

### "Claude quit unexpectedly" on launch
The ASAR integrity fuse was not properly disabled. Re-run `./patch.sh --install` — it handles this automatically. If the problem persists, check that `npx` works: `npx --yes @electron/fuses --help`.

### "Neither asar nor npx found"
Install Node.js: `brew install node` or download from [nodejs.org](https://nodejs.org/).

### The patch doesn't seem to work (no RTL alignment)
- Make sure you're running `Claude-RTL.app` from `~/Applications/`, not the original `Claude.app`
- The RTL detection activates when you type Hebrew/Arabic characters — try typing `שלום עולם`
- Check Console.app for `[Claude RTL]` log messages

### Keychain prompt: "Claude wants to use your confidential information"
On first launch, macOS will show a dialog asking for your password to allow access to **"Claude Safe Storage"** in your keychain. **This is safe to approve.** Claude Desktop uses Electron's `safeStorage` API to encrypt local data (like your login session). Since the patched copy has a different code signature than the original, macOS asks you to re-authorize access. This is a one-time prompt — macOS remembers the approval for future launches.

### macOS Gatekeeper warning
Since the app is ad-hoc signed (not signed by Anthropic), macOS may show a warning on first launch. Right-click → Open to bypass it, or go to System Settings → Privacy & Security → Open Anyway.

## App icon

The patched `Claude-RTL.app` has a custom icon with a visible **"RTL" badge** in the bottom-right corner, making it easy to distinguish from the original Claude.app in the Dock and Finder. The badge uses a white background with a dark border, so it's visible on both light and dark wallpapers/themes.

## Project structure

```
claude-desktop-rtl-mac/
├── patch.sh          # Main patcher script
├── rtl-payload.js    # RTL detection JS (injected into Claude)
├── icon.icns         # RTL-badged app icon
├── README.md
└── LICENSE
```

## Credits

- **RTL detection logic**: [@shraga100](https://github.com/shraga100) — [claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch)
- **macOS adaptation**: this project

## License

MIT — see [LICENSE](LICENSE).

The RTL detection JavaScript (`rtl-payload.js`) is from [claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch), which is also MIT licensed.
