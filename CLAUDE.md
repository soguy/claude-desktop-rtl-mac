# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A macOS-specific patcher that adds RTL (Hebrew/Arabic) support to Claude Desktop. It does **not** modify the original `/Applications/Claude.app` — it produces a separate patched copy at `~/Applications/Claude-RTL.app`. The RTL detection JS (`rtl-payload.js`) is from the upstream Windows project [shraga100/claude-desktop-rtl-patch](https://github.com/shraga100/claude-desktop-rtl-patch); the value-add of this repo is the macOS patching pipeline.

## Commands

```bash
./patch.sh --install     # Build patched copy at ~/Applications/Claude-RTL.app and launch it
./patch.sh --uninstall   # Delete the patched copy (original is never touched)
./patch.sh --status      # Show installed versions + ASAR fuse state
./patch.sh               # Interactive menu
```

`--install` is idempotent — re-running it removes any prior patched copy first, and the JS injection itself is guarded by a `CLAUDE RTL PATCH START` marker. There is no test suite, lint, or build step; the only artifact is the patched `.app` bundle.

Runtime deps (checked by `check_dependencies` in [patch.sh:83](patch.sh#L83)): `npx` (Node ≥16, used to fetch `@electron/asar` and `@electron/fuses` on demand) and `codesign` (Xcode CLI tools). No `package.json` — npm tooling is invoked via `npx --yes`.

## Patching pipeline (patch.sh)

The whole pipeline lives in [patch.sh](patch.sh) — a single bash script with `set -euo pipefail`. Steps in `install_patch` ([patch.sh:130](patch.sh#L130)):

1. `cp -R` the source app to `~/Applications/Claude-RTL.app`.
2. Replace `Contents/Resources/electron.icns` with `icon.icns` and **delete** `CFBundleIconName` from `Info.plist` — macOS prefers the asset-catalog icon over the `.icns` file unless that key is removed ([patch.sh:162](patch.sh#L162)).
3. Set `CFBundleDisplayName=Claude-RTL`. Do **not** change `CFBundleName` — Electron's fuse lookup reads `CFBundleName` and changing it breaks the next step ([patch.sh:169](patch.sh#L169)).
4. `asar extract` → prepend `rtl-payload.js` to every `.js` file under `.vite/build/` → `asar pack`. The injection is skipped per-file if the marker is already present ([patch.sh:188](patch.sh#L188)).
5. `@electron/fuses write … EnableEmbeddedAsarIntegrityValidation=off`. **Required** — Electron validates the ASAR hash at startup and the modified archive will crash the app without this.
6. `codesign --force --deep --sign - --entitlements <plist>` (ad-hoc). The original Anthropic signature is invalidated by the ASAR/fuse changes; ad-hoc signing is what lets macOS launch the modified bundle. Entitlements are extracted from `$SOURCE_APP` and re-applied — without them, runtime entitlement checks fail (notably Cowork, which calls `@ant/claude-swift`'s VM check and shows "installation appears to be corrupted" when `com.apple.security.virtualization` is missing). Three team-id-coupled keys are stripped before re-signing: `com.apple.application-identifier`, `com.apple.developer.team-identifier`, `keychain-access-groups` — they reference Anthropic's team ID `Q6L2SF6YDW` and macOS rejects them under an ad-hoc signature.

`quit_claude_rtl` ([patch.sh:113](patch.sh#L113)) is deliberately scoped to the `Claude-RTL.app` bundle path so it never touches the user's running original Claude Desktop or Claude Code CLI.

## RTL payload (rtl-payload.js)

A self-contained IIFE wrapped in `// --- CLAUDE RTL PATCH START ---` / `--- END ---` markers (the start marker is what `patch.sh` greps for to skip already-patched files). Bails out early if `document` is undefined so it's safe to prepend to any renderer bundle, including ones that may run in a non-DOM context. Uses a `MutationObserver` to handle Claude's streamed responses and force-keeps `<pre>`/`<code>` LTR. When editing payload behavior, preserve the start/end marker comments — removing them breaks idempotency.

## Things that will trip you up

- **Don't patch `/Applications/Claude.app`.** That bundle is root-owned and protected by macOS App Management; modifying it would require sudo and would also break Anthropic's auto-updates. The "copy to `~/Applications/`" design is the whole point.
- **Claude updates ≠ patched copy updates.** Anthropic's auto-updater only updates the original. After a Claude update the user must re-run `./patch.sh --install` to rebuild the patched copy from the new version.
- **`.vite/build/` is the injection target** — if Anthropic restructures the ASAR, the script dies with a clear error at [patch.sh:182](patch.sh#L182). That's the first place to look when a new Claude version breaks the patch.
- **Keychain re-auth is expected on first launch** of the patched copy. Different code signature ⇒ macOS asks the user to re-approve "Claude Safe Storage" access. Not a bug.
