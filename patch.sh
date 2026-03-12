#!/bin/bash
# ============================================================================
# Claude Desktop RTL Patcher for macOS
#
# Adds automatic RTL (right-to-left) support to Claude Desktop on macOS.
# Detects Hebrew/Arabic text and adjusts alignment in real-time — both in
# the chat input and in Claude's responses — while keeping code blocks LTR.
#
# Based on: https://github.com/shraga100/claude-desktop-rtl-patch (Windows)
# RTL detection JS payload by @shraga100, adapted for macOS by this project.
#
# How it works:
#   1. Copies Claude.app to ~/Applications/Claude-RTL.app (original untouched)
#   2. Extracts the app.asar archive
#   3. Prepends RTL detection JS into the renderer build files
#   4. Repacks the archive
#   5. Disables the Electron ASAR integrity fuse (required to load modified archive)
#   6. Re-signs the app with an ad-hoc signature
#
# Requirements: Node.js (for npx/asar) — see README for details
# ============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD_FILE="$SCRIPT_DIR/rtl-payload.js"
ICON_FILE="$SCRIPT_DIR/icon.icns"

SOURCE_APP="/Applications/Claude.app"
PATCHED_APP="$HOME/Applications/Claude-RTL.app"
PATCHED_ASAR="$PATCHED_APP/Contents/Resources/app.asar"

TMP_DIR=""

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()     { echo -e "  ${CYAN}[*]${NC} $1"; }
success() { echo -e "  ${GREEN}[+]${NC} $1"; }
warn()    { echo -e "  ${YELLOW}[!]${NC} $1"; }
err()     { echo -e "  ${RED}[X]${NC} $1"; }
step()    { echo -e "\n${BOLD}${CYAN}► $1${NC}"; }

die() { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
    if [ -n "$TMP_DIR" ] && [ -d "$TMP_DIR" ]; then
        rm -rf "$TMP_DIR" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Dependency helpers
# ---------------------------------------------------------------------------
asar_cmd() {
    if command -v asar &>/dev/null; then
        asar "$@"
    elif command -v npx &>/dev/null; then
        npx --yes @electron/asar "$@"
    else
        die "Bug: asar_cmd called without asar or npx available."
    fi
}

fuses_cmd() {
    if command -v npx &>/dev/null; then
        npx --yes @electron/fuses "$@"
    else
        die "Bug: fuses_cmd called without npx available."
    fi
}

check_dependencies() {
    local missing=()

    if ! command -v npx &>/dev/null && ! command -v asar &>/dev/null; then
        missing+=("Node.js (provides npx) or @electron/asar (npm install -g @electron/asar)")
    fi

    if ! command -v npx &>/dev/null; then
        missing+=("Node.js (provides npx, needed for @electron/fuses)")
    fi

    if ! command -v codesign &>/dev/null; then
        missing+=("Xcode Command Line Tools (provides codesign)")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        err "Missing required dependencies:"
        for dep in "${missing[@]}"; do
            echo -e "    - $dep"
        done
        echo ""
        echo "  Install Node.js: https://nodejs.org/ or 'brew install node'"
        echo "  Install Xcode CLI tools: xcode-select --install"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Claude process management
# ---------------------------------------------------------------------------
quit_claude_rtl() {
    # Only quit the patched RTL copy, not the original Claude or Claude Code
    if pgrep -f "Claude-RTL.app" &>/dev/null; then
        step "Quitting Claude-RTL..."
        # Use bundle identifier approach to be precise
        osascript -e 'tell application "Claude-RTL" to quit' 2>/dev/null || true
        sleep 2
        # If still running, force kill only the exact process
        pkill -f "Claude-RTL.app/Contents/MacOS" 2>/dev/null || true
        sleep 1
        success "Claude-RTL stopped."
    fi
}

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
install_patch() {
    echo -e "\n${BOLD}${CYAN}=======================================================${NC}"
    echo -e "${BOLD}${CYAN}     Claude Desktop RTL Patcher — Install${NC}"
    echo -e "${BOLD}${CYAN}=======================================================${NC}\n"

    # --- Preflight ---
    [ ! -d "$SOURCE_APP" ] && die "Claude.app not found at $SOURCE_APP. Is Claude Desktop installed?"
    [ ! -f "$PAYLOAD_FILE" ] && die "rtl-payload.js not found at $PAYLOAD_FILE. Re-clone the repository."

    check_dependencies

    quit_claude_rtl

    # --- Copy ---
    step "Creating patched copy..."
    mkdir -p "$HOME/Applications"

    if [ -d "$PATCHED_APP" ]; then
        log "Removing previous patched copy..."
        rm -rf "$PATCHED_APP"
    fi

    log "Copying Claude.app → Claude-RTL.app (this may take a moment)..."
    cp -R "$SOURCE_APP" "$PATCHED_APP"
    success "Created $PATCHED_APP"

    # --- Replace icon ---
    if [ -f "$ICON_FILE" ]; then
        step "Replacing app icon..."
        cp "$ICON_FILE" "$PATCHED_APP/Contents/Resources/electron.icns"
        # macOS prefers CFBundleIconName (asset catalog) over CFBundleIconFile (icns).
        # Remove CFBundleIconName so our custom .icns is used instead.
        /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null || true
        success "Icon replaced with RTL-badged version."
    fi

    # --- Rename app in Dock / window title ---
    step "Renaming app to Claude-RTL..."
    # Use CFBundleDisplayName (cosmetic only) — changing CFBundleName breaks Electron's fuse lookup.
    /usr/libexec/PlistBuddy -c "Add :CFBundleDisplayName string Claude-RTL" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null \
        || /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Claude-RTL" "$PATCHED_APP/Contents/Info.plist"
    success "App will show as \"Claude-RTL\" in Dock and Finder."

    # --- Extract ASAR ---
    TMP_DIR=$(mktemp -d)
    step "Extracting app.asar..."
    asar_cmd extract "$PATCHED_ASAR" "$TMP_DIR/app"
    success "Extracted."

    # --- Inject RTL JS ---
    step "Injecting RTL code..."
    BUILD_DIR="$TMP_DIR/app/.vite/build"
    if [ ! -d "$BUILD_DIR" ]; then
        die ".vite/build/ not found in extracted ASAR. Claude Desktop may have changed its internal structure."
    fi

    INJECTED=0
    SKIPPED=0
    for js_file in "$BUILD_DIR"/*.js; do
        [ -f "$js_file" ] || continue

        # Skip already-patched files (idempotent)
        if grep -q "CLAUDE RTL PATCH START" "$js_file" 2>/dev/null; then
            SKIPPED=$((SKIPPED + 1))
            continue
        fi

        # Prepend payload to each JS file
        cat "$PAYLOAD_FILE" "$js_file" > "$TMP_DIR/merged.js"
        mv "$TMP_DIR/merged.js" "$js_file"
        INJECTED=$((INJECTED + 1))
        log "Injected into: $(basename "$js_file")"
    done

    if [ "$INJECTED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]; then
        die "No .js files found in .vite/build/. Claude Desktop structure may have changed."
    fi

    [ "$INJECTED" -gt 0 ] && success "Injected RTL JS into $INJECTED file(s)."
    [ "$SKIPPED" -gt 0 ] && log "Skipped $SKIPPED already-patched file(s)."

    # --- Repack ASAR ---
    step "Repacking app.asar..."
    asar_cmd pack "$TMP_DIR/app" "$TMP_DIR/app.asar.new"
    cp "$TMP_DIR/app.asar.new" "$PATCHED_ASAR"
    success "Repacked."

    # --- Disable ASAR integrity fuse ---
    step "Disabling ASAR integrity validation..."
    log "Electron embeds a fuse that validates the ASAR archive hash at startup."
    log "Since we modified the archive, this fuse must be disabled or the app will crash."
    fuses_cmd write --app "$PATCHED_APP" EnableEmbeddedAsarIntegrityValidation=off 2>&1 | while IFS= read -r line; do
        log "$line"
    done
    success "ASAR integrity fuse disabled."

    # --- Re-sign ---
    step "Re-signing with ad-hoc signature..."
    log "The original code signature is invalidated by our changes."
    log "An ad-hoc signature allows macOS to run the modified app."
    codesign --force --deep --sign - "$PATCHED_APP" 2>&1 | while IFS= read -r line; do
        log "$line"
    done
    success "App re-signed."

    # --- Cleanup temp ---
    rm -rf "$TMP_DIR" 2>/dev/null || true
    TMP_DIR=""

    # --- Launch ---
    step "Launching Claude-RTL..."
    open "$PATCHED_APP"

    echo -e "\n${BOLD}${GREEN}=======================================================${NC}"
    echo -e "${BOLD}${GREEN}     PATCH INSTALLED SUCCESSFULLY!${NC}"
    echo -e "${BOLD}${GREEN}=======================================================${NC}"
    echo ""
    echo -e "  Patched app:  ${BOLD}$PATCHED_APP${NC}"
    echo -e "  Original app: ${BOLD}$SOURCE_APP${NC} (untouched)"
    echo ""
    echo "  You can keep both apps. The original Claude.app is not modified."
    echo "  To remove the patch, run: $0 --uninstall"
    echo ""
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
uninstall_patch() {
    echo -e "\n${BOLD}${CYAN}=======================================================${NC}"
    echo -e "${BOLD}${CYAN}     Claude Desktop RTL Patcher — Uninstall${NC}"
    echo -e "${BOLD}${CYAN}=======================================================${NC}\n"

    if [ ! -d "$PATCHED_APP" ]; then
        warn "No patched app found at $PATCHED_APP. Nothing to remove."
        exit 0
    fi

    quit_claude_rtl

    step "Removing patched app..."
    rm -rf "$PATCHED_APP"
    success "Removed $PATCHED_APP"

    echo -e "\n${BOLD}${GREEN}=======================================================${NC}"
    echo -e "${BOLD}${GREEN}     UNINSTALL COMPLETED${NC}"
    echo -e "${BOLD}${GREEN}=======================================================${NC}"
    echo ""
    echo "  The original Claude.app at $SOURCE_APP was never modified."
    echo ""
}

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
show_status() {
    echo ""
    echo -e "${BOLD}Claude Desktop RTL Patch — Status${NC}"
    echo ""

    if [ -d "$SOURCE_APP" ]; then
        local version
        version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$SOURCE_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")
        success "Original Claude.app: installed (v$version)"
    else
        warn "Original Claude.app: not found"
    fi

    if [ -d "$PATCHED_APP" ]; then
        local patched_version
        patched_version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PATCHED_APP/Contents/Info.plist" 2>/dev/null || echo "unknown")

        # Check if it's actually patched (fuse disabled)
        local fuse_status
        fuse_status=$(npx --yes @electron/fuses read --app "$PATCHED_APP" 2>/dev/null | grep "EnableEmbeddedAsarIntegrityValidation" || echo "unknown")

        if echo "$fuse_status" | grep -q "Disabled"; then
            success "Patched Claude-RTL.app: installed (v$patched_version, fuse disabled)"
        else
            warn "Patched Claude-RTL.app: found (v$patched_version) but fuse status unclear"
        fi
    else
        log "Patched Claude-RTL.app: not installed"
    fi

    echo ""
}

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    echo ""
    echo -e "${BOLD}Claude Desktop RTL Patcher for macOS${NC}"
    echo ""
    echo "Usage: $0 [OPTION]"
    echo ""
    echo "Options:"
    echo "  --install     Install the RTL patch (creates ~/Applications/Claude-RTL.app)"
    echo "  --uninstall   Remove the patched app"
    echo "  --status      Show current patch status"
    echo "  --help        Show this help message"
    echo ""
    echo "If no option is given, an interactive menu is shown."
    echo ""
}

# ---------------------------------------------------------------------------
# Interactive menu
# ---------------------------------------------------------------------------
interactive_menu() {
    echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${CYAN}║   Claude Desktop RTL Patcher (macOS)            ║${NC}"
    echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  1. Install RTL Patch"
    echo "  2. Uninstall (remove patched app)"
    echo "  3. Show Status"
    echo "  4. Exit"
    echo ""
    read -rp "Enter your choice (1-4): " choice

    case "$choice" in
        1) install_patch ;;
        2) uninstall_patch ;;
        3) show_status ;;
        4) exit 0 ;;
        *) err "Invalid choice."; exit 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
case "${1:-}" in
    --install)   install_patch ;;
    --uninstall) uninstall_patch ;;
    --status)    show_status ;;
    --help|-h)   usage ;;
    "")          interactive_menu ;;
    *)           err "Unknown option: $1"; usage; exit 1 ;;
esac
