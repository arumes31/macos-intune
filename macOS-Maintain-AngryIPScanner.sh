#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-AngryIPScanner.sh
# Description:    Unified Detect & Patch script for Angry IP Scanner on macOS via Intune.
#                 Queries GitHub API for the latest version, downloads the
#                 architecture-specific ZIP, extracts and installs the application.
# ==============================================================================

APP_NAME="Angry IP Scanner.app"
APP_PATH="/Applications/$APP_NAME"
TEMP_DIR=$(mktemp -d "/private/tmp/angryip_update.XXXXXX") || { echo "[FATAL] Could not create a private temporary directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
ZIP_PATH="$TEMP_DIR/angryip.zip"
EXPECTED_SHA256=${ANGRYIP_EXPECTED_SHA256:-}

echo "[START] Initiating Angry IP Scanner version alignment assessment..."

# 1. Identify local system architecture and map it to Angry IP Scanner's asset naming.
# Release assets are named "ipscan-macArm64-<version>.zip" / "ipscan-macX86-<version>.zip"
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ASSET_ARCH="macArm64"
else
    ASSET_ARCH="macX86"
fi
echo "[INFO] System Architecture detected: $ARCH (asset tag: $ASSET_ARCH)"

# ------------------------------------------------------------------------------
# PHASE 1: ZERO-DOWNLOAD API VERSION CHECK
# ------------------------------------------------------------------------------
echo "[INFO] Fetching metadata from latest stable GitHub release..."
RELEASE_JSON=$(curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 30 "https://api.github.com/repos/angryip/ipscan/releases/latest")

if [ -z "$RELEASE_JSON" ]; then
    echo "[WARN] Unable to reach GitHub API. Skipping patch cycle to preserve network."
    exit 0
fi

# Extract target production version string safely without requiring jq
VENDOR_VERSION=$(echo "$RELEASE_JSON" | grep -m 1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/')
echo "[INFO] Latest Version Released by Vendor: $VENDOR_VERSION"

# Dynamically parse the download link for this architecture.
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*' | grep -i "$ASSET_ARCH" | head -n 1 | awk -F '"' '{print $4}')

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
        echo "[COMPLIANT] Angry IP Scanner is fully up to date. Exiting with zero network consumption."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] Angry IP Scanner is not installed on this endpoint. Forcing initialization."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF ANGRY IP SCANNER IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -f "Angry IP Scanner" >/dev/null || pgrep -x "ipscan" >/dev/null; then
    echo "[DEFERRED] Angry IP Scanner process tree is active. Postponing upgrade to avoid data loss."
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & IN-PLACE UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    if ! printf '%s' "$EXPECTED_SHA256" | grep -Eq '^[a-fA-F0-9]{64}$'; then
        echo "[FATAL] ANGRYIP_EXPECTED_SHA256 must pin the approved release asset before installation."
        exit 1
    fi
    echo "[PROCEEDING] Downloading the approved architecture-matched release payload."
    mkdir -p "$TEMP_DIR"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$ZIP_PATH")

    HTTP_STATUS=${HTTP_STATUS:-000}
    if [ "$HTTP_STATUS" != "200" ]; then
        echo "[FATAL] Download failed with unexpected HTTP Status: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    ACTUAL_SHA256=$(/usr/bin/shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "[FATAL] Downloaded ZIP does not match ANGRYIP_EXPECTED_SHA256."
        exit 1
    fi

    # Verify ZIP integrity
    if ! unzip -tqq "$ZIP_PATH" >/dev/null 2>&1; then
        echo "[FATAL] Downloaded ZIP failed integrity test. Aborting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    echo "[INFO] Inflating zip container..."
    unzip -q -o "$ZIP_PATH" -d "$TEMP_DIR"
    rm -rf "$TEMP_DIR/__MACOSX"

    # Locate the unzipped app bundle
    UNZIPPED_APP=$(find "$TEMP_DIR" -name "Angry IP Scanner.app" -type d -not -path '*/__MACOSX/*' | head -n 1)

    if [ -z "$UNZIPPED_APP" ] || [ ! -d "$UNZIPPED_APP" ]; then
        echo "[FATAL] Failed to unpack a valid Angry IP Scanner.app bundle."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Angry IP Scanner macOS builds are unsigned, so installation is allowed only
    # after matching the operator-pinned release checksum above.
    echo "[SECURITY] Unsigned vendor payload matched the operator-pinned SHA-256."

    echo "[INFO] Overwriting older binaries in /Applications..."
    rm -rf "$APP_PATH"
    
    if cp -R "$UNZIPPED_APP" "/Applications/"; then
        echo "[SUCCESS] Angry IP Scanner bundle written successfully."
        
        # De-quarantine so Gatekeeper doesn't block first launch
        echo "[SECURITY] De-quarantining the application bundle..."
        xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null
        
        # Fix app directory ownership back to the active user
        CURRENT_USER=$(stat -f '%Su' /dev/console)
        if [ "$CURRENT_USER" != "root" ] && [ "$CURRENT_USER" != "loginwindow" ] && [ -n "$CURRENT_USER" ]; then
            echo "[INFO] Elevating folder ownership permissions to active user: $CURRENT_USER"
            chown -R "$CURRENT_USER":staff "$APP_PATH"
        fi
    else
        echo "[ERROR] Copy failure from extracted ZIP to destination drive."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # Cleanup environments
    rm -rf "$TEMP_DIR"
fi

echo "[FINISH] Angry IP Scanner maintenance run completed."
exit 0
