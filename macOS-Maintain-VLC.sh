#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-VLC.sh
# Description:    Unified Detect & Patch script for VLC Media Player via Intune.
#                 Queries Sparkle XML appcast natively for architecture-aware updates.
# ==============================================================================

APP_NAME="VLC.app"
APP_PATH="/Applications/$APP_NAME"
TEMP_DIR=$(mktemp -d "/private/tmp/vlc_update.XXXXXX") || { echo "[FATAL] Could not create a private temporary directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/vlc.dmg"

# Apple Developer Team ID for VideoLAN. The mounted app must match before we copy it.
EXPECTED_TEAMID="75GAHG3SZQ"

# Stable Sparkle Appcast Feed managed by VideoLAN
APPCAST_URL="https://update.videolan.org/vlc/sparkle/vlc-intel64.xml"

echo "[START] Initiating VLC version alignment assessment..."

# 1. Identify local system architecture to map the correct download binary
SYS_ARCH=$(uname -m)
if [ "$SYS_ARCH" = "arm64" ]; then
    ARCH_SUFFIX="arm64"
else
    ARCH_SUFFIX="intel64"
fi
echo "[INFO] Architecture target classified: $ARCH_SUFFIX"

# ------------------------------------------------------------------------------
# PHASE 1: ZERO-DOWNLOAD APPCAST XML VERSION CHECK
# ------------------------------------------------------------------------------
echo "[INFO] Extracting live deployment manifest from VideoLAN..."
APPCAST_DATA=$(curl -fsSL --proto '=https' --proto-redir '=https' "$APPCAST_URL" --connect-timeout 10 --max-time 15)

if [ -z "$APPCAST_DATA" ]; then
    echo "[WARN] Unable to reach VideoLAN Appcast infrastructure. Deferring run."
    exit 0
fi

# Parse the NEWEST production version from the Sparkle feed. The appcast lists entries
# oldest-first, so "head -n1" would pick the most ancient build (1.1.3). Extract every
# sparkle:version and pick the highest with a version-aware sort.
VENDOR_VERSION=$(echo "$APPCAST_DATA" \
    | grep -oE 'sparkle:version="[0-9.]+"' \
    | cut -d'"' -f2 \
    | sort -V | tail -n 1)

if [ -z "$VENDOR_VERSION" ]; then
    echo "[WARN] Could not parse version data from XML packet stream. Skipping."
    exit 0
fi
echo "[INFO] Latest Version Released by Vendor: $VENDOR_VERSION"

# Construct the dynamic, architecture-optimized download path
DOWNLOAD_URL="https://get.videolan.org/vlc/${VENDOR_VERSION}/macosx/vlc-${VENDOR_VERSION}-${ARCH_SUFFIX}.dmg"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString")
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] VLC Media Player is fully up to date. Closing session with zero data waste."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] VLC is not installed on this endpoint. Initializing first-time rollout."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF VLC IS ACTIVELY STREAMING MEDIA
# ------------------------------------------------------------------------------
if pgrep -x "VLC" > /dev/null; then
    echo "[DEFERRED] VLC process tree is active. User may be streaming media or in a presentation."
    echo "[DEFERRED] Postponing upgrade execution to preserve user experience."
    # Exit 0 keeps the Intune engine happy and schedules evaluation for the next loop run
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & IN-PLACE UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    echo "[PROCEEDING] Downloading optimized DMG payload..."
    mkdir -p "$TEMP_DIR"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$DMG_PATH")

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "[FATAL] Download failed from VideoLAN CDNs with HTTP status: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    echo "[INFO] Mounting disk volume..."
    MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | grep -E '/Volumes/.*' | awk -F'\t' '{print $NF}' | head -n 1)

    if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT/$APP_NAME" ]; then
        echo "[FATAL] Mount sequence failed or app bundle corrupt within DMG wrapper."
        [[ -n "$MOUNT_POINT" ]] && hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: verify the signature + Team ID of the app inside the DMG before copying.
    if ! /usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME" 2>/dev/null \
       || ! /usr/bin/codesign -dvv "$MOUNT_POINT/$APP_NAME" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
        echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] App signature verified (Team ID $EXPECTED_TEAMID)."

    echo "[INFO] Replacing outdated binary infrastructure inside /Applications..."
    rm -rf "$APP_PATH"
    
    if cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"; then
        echo "[SUCCESS] VLC app bundle written successfully to system target."
        
        # Strip the web quarantine tag to prevent Gatekeeper blockage alerts
        xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null

        # Restore app workspace ownership back to the active user to avoid local preference
        # write failures and recurring TCC/permission prompts.
        CURRENT_USER=$(stat -f '%Su' /dev/console)
        if [ "$CURRENT_USER" != "root" ] && [ "$CURRENT_USER" != "loginwindow" ] && [ -n "$CURRENT_USER" ]; then
            echo "[INFO] Assigning folder ownership rights to active user: $CURRENT_USER"
            chown -R "$CURRENT_USER":staff "$APP_PATH"
        fi
    else
        echo "[ERROR] Copy operation failed from mounted DMG to /Applications."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # --------------------------------------------------------------------------
    # PHASE 4: POST-EXECUTION CLEANUP
    # --------------------------------------------------------------------------
    echo "[INFO] Detaching disk volume and purging scratch space..."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"

    echo "[SUCCESS] VLC Media Player upgraded to version $VENDOR_VERSION."
fi

echo "[FINISH] VLC maintenance run completed."
exit 0
