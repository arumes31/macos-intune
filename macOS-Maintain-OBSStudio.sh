#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-OBSStudio.sh
# Description:    Unified Detect & Patch script for OBS Studio on macOS via Intune.
#                 Queries GitHub API for the latest release, downloads the DMG
#                 optimized for the architecture, and mounts and installs the app.
# ==============================================================================

APP_NAME="OBS.app"
APP_PATH="/Applications/$APP_NAME"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/obs_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/OBS.dmg"

# Apple Developer Team ID for OBS Project. The mounted app must match before copy.
EXPECTED_TEAMID="2MMRE5MTB8"

echo "[START] Initiating OBS Studio version alignment assessment..."

# 1. Identify local system architecture and map it to OBS's asset naming.
# Release assets are named "...-macOS-Apple.dmg" (ARM64) or "...-macOS-Intel.dmg" (Intel)
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ASSET_ARCH="Apple"
else
    ASSET_ARCH="Intel"
fi
echo "[INFO] System Architecture detected: $ARCH (asset tag: $ASSET_ARCH)"

# GitHub API Release Endpoint
API_URL="https://api.github.com/repos/obsproject/obs-studio/releases/latest"

# ------------------------------------------------------------------------------
# PHASE 1: ZERO-DOWNLOAD API VERSION CHECK
# ------------------------------------------------------------------------------
echo "[INFO] Fetching metadata from latest stable GitHub release..."
RELEASE_JSON=$(curl -sL "$API_URL")

if [ -z "$RELEASE_JSON" ]; then
    echo "[WARN] Unable to reach GitHub API. Skipping patch cycle to preserve network."
    exit 0
fi

# Extract target production version string safely without requiring jq
VENDOR_VERSION=$(echo "$RELEASE_JSON" | grep -m 1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/')
echo "[INFO] Latest Version Released by Vendor: $VENDOR_VERSION"

# Dynamically parse the download link for this architecture.
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*' | grep -i "$ASSET_ARCH" | grep -iE '\.dmg"?$' | head -n 1 | awk -F '"' '{print $4}')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[FATAL] Script failed to isolate a valid installer URL payload."
    exit 1
fi


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString" 2>/dev/null)
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] OBS Studio is fully up to date. Exiting with zero network consumption."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] OBS Studio is not installed on this endpoint. Forcing initialization."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF OBS STUDIO IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -x "OBS" >/dev/null || pgrep -x "obs" >/dev/null; then
    echo "[DEFERRED] OBS Studio process is active. Postponing upgrade to avoid closing user streams."
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & IN-PLACE UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    echo "[PROCEEDING] Downloading payload from URL: $DOWNLOAD_URL"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$DMG_PATH")

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "[FATAL] Download failed with unexpected HTTP Status: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Confirm the payload landed and is valid
    if [ ! -s "$DMG_PATH" ]; then
        echo "[FATAL] Download reported HTTP 200 but no file was written to $DMG_PATH. Aborting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    if ! hdiutil imageinfo "$DMG_PATH" >/dev/null 2>&1; then
        echo "[FATAL] Downloaded file is not a valid disk image. Aborting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    echo "[INFO] Mounting disk volume..."
    ATTACH_OUT=$(yes 2>/dev/null | hdiutil attach -nobrowse -noverify -noautoopen -readonly "$DMG_PATH" 2>&1)
    ATTACH_RC=$?
    if [ "$ATTACH_RC" -ne 0 ]; then
        echo "[FATAL] hdiutil attach failed (rc=$ATTACH_RC): $ATTACH_OUT"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    MOUNT_POINT=$(echo "$ATTACH_OUT" | grep -E '/Volumes/.*' | awk -F'\t' '{print $NF}' | head -n 1)

    if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT/$APP_NAME" ]; then
        echo "[FATAL] Mount sequence failed or app bundle corrupt within DMG wrapper."
        [[ -n "$MOUNT_POINT" ]] && hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: verify the app signature + Team ID of the mounted bundle before copying
    if ! /usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME" 2>/dev/null \
       || ! /usr/bin/codesign -dvv "$MOUNT_POINT/$APP_NAME" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
        echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] App signature verified (Team ID $EXPECTED_TEAMID)."

    echo "[INFO] Overwriting older binaries in /Applications..."
    rm -rf "$APP_PATH"
    
    if cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"; then
        echo "[SUCCESS] OBS Studio app bundle written successfully."
        
        # De-quarantine so Gatekeeper doesn't block first launch
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

echo "[FINISH] OBS Studio maintenance run completed."
exit 0
