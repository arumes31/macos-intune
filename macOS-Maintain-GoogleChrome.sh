#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-GoogleChrome.sh
# Description:    Unified Detect & Patch script for macOS via Intune Scripts.
#                 Checks local vs vendor version before executing download.
# ==============================================================================

APP_NAME="Google Chrome.app"
APP_PATH="/Applications/$APP_NAME"
# Universal stable DMG. The old unauthenticated googlechrome.pkg path now 404s
# (the PKG requires a per-session accept_tos token from the enterprise portal),
# so we pull the always-current DMG and copy the app bundle into place instead.
DOWNLOAD_URL="https://dl.google.com/chrome/mac/stable/GoogleChrome.dmg"
TEMP_DIR="/private/tmp/chrome_update"
DMG_PATH="$TEMP_DIR/GoogleChrome.dmg"

# Apple Developer Team ID for Google LLC. The mounted app must match before we copy it.
EXPECTED_TEAMID="EQHXZ8M8AV"

echo "[START] Evaluating Google Chrome version status..."

# ------------------------------------------------------------------------------
# PHASE 1: DETECTION
# ------------------------------------------------------------------------------
# Fetch live production version string from Google's release backend.
# NOTE: the API emits "version":"NN" with NO space after the colon, so the old
# '"version": "' pattern matched nothing and the script always skipped.
VENDOR_VERSION=$(curl -s "https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac" | grep -oE '"version":[[:space:]]*"[0-9.]+"' | grep -oE '[0-9.]+' | head -n 1)

if [ -z "$VENDOR_VERSION" ]; then
    echo "[WARN] Could not reach vendor API to check latest version. Skipping run to prevent broken downloads."
    exit 0
fi

# Check if app is installed; if missing, we skip straight to installation phase
if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString")
    echo "[INFO] Current Local Version: $LOCAL_VERSION"
    echo "[INFO] Latest Vendor Version: $VENDOR_VERSION"

    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Application is fully up to date. Exiting cleanly."
        exit 0
    fi
    echo "[OUTDATED] Local version ($LOCAL_VERSION) is older than vendor version ($VENDOR_VERSION)."
else
    echo "[MISSING] Google Chrome is not installed on this machine."
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF CHROME IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -x "Google Chrome" > /dev/null; then
    echo "[DEFERRED] Google Chrome is actively running. Postponing to avoid closing user tabs."
    exit 0
fi

# ------------------------------------------------------------------------------
# PHASE 2: REMEDIATION (Only runs if code above didn't exit 0)
# ------------------------------------------------------------------------------
echo "[PROCEEDING] Starting download and upgrade pipeline..."
mkdir -p "$TEMP_DIR"

# Resilient download with HTTP validation
HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$DMG_PATH")

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "[FATAL] Network error: CDN returned HTTP Status $HTTP_STATUS. Aborting installation."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "[INFO] Mounting disk image volume..."
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

echo "[INFO] Overwriting older binary in /Applications..."
rm -rf "$APP_PATH"

if cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"; then
    echo "[SUCCESS] Google Chrome upgraded successfully to version $VENDOR_VERSION."

    # De-quarantine so Gatekeeper doesn't block first launch
    xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null

    # Restore ownership to the active console user
    CURRENT_USER=$(stat -f '%Su' /dev/console)
    if [ "$CURRENT_USER" != "root" ] && [ "$CURRENT_USER" != "loginwindow" ] && [ -n "$CURRENT_USER" ]; then
        chown -R "$CURRENT_USER":staff "$APP_PATH"
    fi

    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 0
else
    echo "[ERROR] Copy operation failed from mounted DMG to /Applications."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi