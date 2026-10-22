#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-Flameshot.sh
# Description:    Unified Detect & Patch script for Flameshot on macOS via Intune.
#                 Queries GitHub API natively for architecture-aware updates.
# ==============================================================================

APP_NAME="Flameshot.app"
APP_PATH="/Applications/$APP_NAME"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/flameshot_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/Flameshot.dmg"

echo "[START] Initiating Flameshot update assessment..."

# 1. Identify local system architecture and map it to Flameshot's asset naming.
# Release assets are named "...-macos-arm64.dmg" / "...-macos-intel.dmg", but
# `uname -m` reports "x86_64" on Intel — so matching the raw value picked nothing
# and the fallback grabbed the FIRST dmg (arm64), pushing an arm64 build onto Intel.
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ASSET_ARCH="arm64"
else
    ASSET_ARCH="intel"
fi
echo "[INFO] System Architecture detected: $ARCH (asset tag: $ASSET_ARCH)"

# ------------------------------------------------------------------------------
# PHASE 1: ZERO-DOWNLOAD API VERSION CHECK
# ------------------------------------------------------------------------------
echo "[INFO] Fetching metadata from latest stable GitHub release..."
RELEASE_JSON=$(curl -sL "https://api.github.com/repos/flameshot-org/flameshot/releases/latest")

if [ -z "$RELEASE_JSON" ]; then
    echo "[WARN] Unable to reach GitHub API. Skipping patch cycle to preserve network."
    exit 0
fi

# Extract target production version string safely without requiring jq
VENDOR_VERSION=$(echo "$RELEASE_JSON" | grep -m 1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/')
echo "[INFO] Latest Version Released by Vendor: $VENDOR_VERSION"

# Dynamically parse the download link for this architecture (exclude .sha256sum files).
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*' | grep -i 'mac' | grep -i "$ASSET_ARCH" | grep -iE '\.dmg"?$' | head -n 1 | awk -F '"' '{print $4}')

# Fallback to any macOS dmg if the architecture-specific link isn't isolated
if [ -z "$DOWNLOAD_URL" ]; then
    DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*' | grep -i 'mac' | grep -iE '\.dmg"?$' | head -n 1 | awk -F '"' '{print $4}')
fi

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[FATAL] Script failed to isolate a valid installer URL payload out of GitHub JSON metadata."
    exit 1
fi

# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString")
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Flameshot is fully up to date. Exiting with zero network consumption."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] Flameshot is not installed on this endpoint. Forcing initialization."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & IN-PLACE UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    echo "[PROCEEDING] Downloading payload from URL: $DOWNLOAD_URL"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$DMG_PATH")

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "[FATAL] Download failed with unexpected HTTP Network Token: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: Flameshot is a community build (no pinned Team ID), but each GitHub
    # release publishes an official "<asset>.sha256sum". Verify the download against it
    # to catch tampering / corrupted transfers before we mount and install.
    EXPECTED_SHA=$(curl -fsSL --retry 3 --connect-timeout 15 "${DOWNLOAD_URL}.sha256sum" | awk '{print $1}')
    ACTUAL_SHA=$(/usr/bin/shasum -a 256 "$DMG_PATH" | awk '{print $1}')
    if [ -z "$EXPECTED_SHA" ] || [ "$EXPECTED_SHA" != "$ACTUAL_SHA" ]; then
        echo "[FATAL] SHA-256 checksum mismatch (expected '$EXPECTED_SHA', got '$ACTUAL_SHA'). Refusing to install."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] DMG checksum verified against GitHub-published SHA-256."

    echo "[INFO] Mounting disk volume..."
    MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | grep -E '/Volumes/.*' | awk -F'\t' '{print $NF}' | head -n 1)

    if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT/$APP_NAME" ]; then
        echo "[FATAL] Mount sequence failed or app bundle corrupt within DMG wrapper."
        [[ -n "$MOUNT_POINT" ]] && hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Confirm the app carries a valid (unbroken) code signature before trusting it.
    if ! /usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME" 2>/dev/null; then
        echo "[FATAL] Code signature on Flameshot.app is invalid. Refusing to install."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] App code signature is valid."

    # Gracefully terminate app if running to avoid text file-system locking exceptions
    killall "flameshot" 2>/dev/null
    sleep 2
    
    echo "[INFO] Overwriting older binaries in /Applications..."
    rm -rf "$APP_PATH"
    
    if cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"; then
        echo "[SUCCESS] Flameshot app bundle written successfully."
        
        # ------------------------------------------------------------------------------
        # CRUCIAL GATEKEEPER & PERMISSION FIXES
        # ------------------------------------------------------------------------------
        # 1. Strip the quarantine attribute so users don't get the "Developer cannot be verified" prompt
        echo "[SECURITY] De-quarantining the application bundle..."
        xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null
        
        # SECURITY: keep the bundle root-owned (as vendor pkgs install it). Handing it to
        # the console user would let them tamper with code other users and this script trust.
        chown -R root:wheel "$APP_PATH"
    else
        echo "[ERROR] Copy failure from mounted image to destination drive."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # Cleanup environments
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
fi

echo "[FINISH] Patch tracking operation completed successfully."
exit 0