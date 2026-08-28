#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-Figma.sh
# Description:    Unified Detect & Patch script for Figma on macOS via Intune.
#                 Queries the Figma update API for the latest version, downloads the
#                 architecture-specific ZIP, extracts, verifies, and installs it.
# ==============================================================================

APP_NAME="Figma.app"
APP_PATH="/Applications/$APP_NAME"
TEMP_DIR=$(mktemp -d "/private/tmp/figma_update.XXXXXX") || { echo "[FATAL] Could not create a private temporary directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
ZIP_PATH="$TEMP_DIR/Figma.zip"

# Apple Developer Team ID for Figma Inc. The app signature must match.
EXPECTED_TEAMID="T8RA8NE3B7"

echo "[START] Initiating Figma version alignment assessment..."

# 1. Identify local system architecture and map it to Figma's asset naming.
# Release assets are named "mac-arm" (Apple Silicon) or "mac" (Intel)
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ASSET_ARCH="mac-arm"
else
    ASSET_ARCH="mac"
fi
echo "[INFO] System Architecture detected: $ARCH (asset tag: $ASSET_ARCH)"

# Figma Release metadata URL
API_URL="https://desktop.figma.com/${ASSET_ARCH}/RELEASE.json"

# ------------------------------------------------------------------------------
# PHASE 1: ZERO-DOWNLOAD API VERSION CHECK
# ------------------------------------------------------------------------------
echo "[INFO] Fetching metadata from latest stable release..."
API_JSON=$(curl -fsS --proto '=https' --proto-redir '=https' "$API_URL" --connect-timeout 10 --max-time 30)

if [ -z "$API_JSON" ]; then
    echo "[WARN] Figma update API is unreachable. Skipping patch cycle to preserve network."
    exit 0
fi

# Parse version and download URL from JSON
VENDOR_VERSION=$(echo "$API_JSON" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)
DOWNLOAD_URL=$(echo "$API_JSON" | grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)

if [ -z "$VENDOR_VERSION" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "[WARN] Could not parse version or URL from Figma update API. Skipping run."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString" 2>/dev/null)
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Figma is fully up to date. Exiting with zero network consumption."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] Figma is not installed on this endpoint. Forcing initialization."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF FIGMA IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -x "Figma" >/dev/null || pgrep -x "FigmaAgent" >/dev/null; then
    echo "[DEFERRED] Figma or FigmaAgent process is active. Postponing upgrade to avoid closing user documents."
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & IN-PLACE UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    echo "[PROCEEDING] Downloading the vendor-selected release payload."
    mkdir -p "$TEMP_DIR"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$ZIP_PATH")

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "[FATAL] Download failed with unexpected HTTP Status: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
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
    UNZIPPED_APP=$(find "$TEMP_DIR" -name "Figma.app" -type d -not -path '*/__MACOSX/*' | head -n 1)

    if [ -z "$UNZIPPED_APP" ] || [ ! -d "$UNZIPPED_APP" ]; then
        echo "[FATAL] Failed to unpack a valid Figma.app bundle."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: verify the app signature + Team ID of the unzipped bundle before copying
    if ! /usr/bin/codesign --verify --deep --strict "$UNZIPPED_APP" 2>/dev/null \
       || ! /usr/bin/codesign -dvv "$UNZIPPED_APP" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
        echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] App signature verified (Team ID $EXPECTED_TEAMID)."

    echo "[INFO] Overwriting older binaries in /Applications..."
    rm -rf "$APP_PATH"
    
    if cp -R "$UNZIPPED_APP" "/Applications/"; then
        echo "[SUCCESS] Figma app bundle written successfully."
        
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

echo "[FINISH] Figma maintenance run completed."
exit 0
