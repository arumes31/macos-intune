#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-GoogleChrome.sh
# Description:    Unified Detect & Patch script for macOS via Intune Scripts.
#                 Checks local vs vendor version before executing download.
# ==============================================================================

APP_NAME="Google Chrome.app"
APP_PATH="/Applications/$APP_NAME"
# Universal stable DMG (current Apple-silicon + Intel build).
# NOTE: the shorter dl.google.com/chrome/mac/stable/GoogleChrome.dmg path still
# returns HTTP 200 but is a FROZEN 2015 artifact (Chrome 47.x, ~63 MB, still ships
# PepperFlash) — pulling it would DOWNGRADE every machine. The universal/stable/GGRO
# path is the live channel (~228 MB, current version) and is what Google's own
# enterprise tooling uses.
DOWNLOAD_URL="https://dl.google.com/chrome/mac/universal/stable/GGRO/googlechrome.dmg"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/chrome_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
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

# Resilient download with HTTP validation. The universal DMG is ~265 MB; 600s was too
# tight on throttled/VPN'd managed Macs and truncated the transfer. A truncated DMG
# loses its trailing "koly" block, which is exactly what makes hdiutil report
# "image not recognized". Give slow links 30 min to finish the pull.
HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$DMG_PATH")

# Default to "000" so an empty / non-numeric value can never make the guard below
# error out (integer compare) and get silently treated as success. Use string compare.
HTTP_STATUS=${HTTP_STATUS:-000}
if [ "$HTTP_STATUS" != "200" ]; then
    echo "[FATAL] Network error: CDN returned HTTP Status $HTTP_STATUS. Aborting installation."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Confirm the payload landed and is plausibly the full installer (missing file or a
# truncated transfer would otherwise reach hdiutil and fail cryptically).
if [ ! -s "$DMG_PATH" ]; then
    echo "[FATAL] Download reported HTTP 200 but no file was written to $DMG_PATH. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

DMG_BYTES=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo 0)
if [ "$DMG_BYTES" -lt 52428800 ]; then   # < 50 MB: truncated download, not the ~265 MB full app
    echo "[FATAL] Downloaded DMG is only $DMG_BYTES bytes (expected ~265 MB). Likely truncated. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Validate the disk image structure (needs the trailing koly block) before attaching,
# so a truncated/corrupt file is reported plainly instead of leaking the misleading
# hdiutil "image not recognized" to the Intune console.
if ! hdiutil imageinfo "$DMG_PATH" >/dev/null 2>&1; then
    echo "[FATAL] Downloaded file is not a valid disk image (corrupt or partial transfer). Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "[INFO] Mounting disk image volume ($DMG_BYTES bytes)..."
# Capture hdiutil's own output (incl. stderr) so any future failure is self-explanatory;
# `yes |` harmlessly accepts a SLA prompt if the image ever carries one.
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

# SECURITY: verify the signature + Team ID of the app inside the DMG before copying.
if ! /usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME" 2>/dev/null \
   || ! /usr/bin/codesign -dvv "$MOUNT_POINT/$APP_NAME" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
    echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "[SECURITY] App signature verified (Team ID $EXPECTED_TEAMID)."

# chromiumdash publishes the newest Stable push, which can lead the universal DMG on
# the CDN by a few hours. Comparing the installed build against that leading number
# meant LOCAL_VERSION never matched VENDOR_VERSION, so every run re-downloaded and
# re-copied the SAME build. Trust the real bundle inside the DMG instead: if it already
# matches what's installed, exit compliant rather than copying the same binary again.
DMG_VERSION=$(defaults read "$MOUNT_POINT/$APP_NAME/Contents/Info.plist" "CFBundleShortVersionString" 2>/dev/null)
# Never downgrade: only copy when the DMG build is strictly newer than what's installed.
# (If the app is missing, LOCAL_VERSION is empty and we fall through to a fresh install.)
if [ -n "$DMG_VERSION" ] && [ -n "$LOCAL_VERSION" ]; then
    NEWEST=$(printf '%s\n%s\n' "$LOCAL_VERSION" "$DMG_VERSION" | sort -V | tail -1)
    if [ "$NEWEST" = "$LOCAL_VERSION" ]; then
        echo "[COMPLIANT] Installed version ($LOCAL_VERSION) is >= current DMG build ($DMG_VERSION). No copy needed."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 0
    fi
fi
[ -n "$DMG_VERSION" ] && VENDOR_VERSION="$DMG_VERSION"

echo "[INFO] Overwriting older binary in /Applications..."
rm -rf "$APP_PATH"

if cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"; then
    echo "[SUCCESS] Google Chrome upgraded successfully to version $VENDOR_VERSION."

    # De-quarantine so Gatekeeper doesn't block first launch
    xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null

    # SECURITY: keep the bundle root-owned (as vendor pkgs install it). Handing it to
    # the console user would let them tamper with code other users and this script trust.
    chown -R root:wheel "$APP_PATH"

    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 0
else
    echo "[ERROR] Copy operation failed from mounted DMG to /Applications."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi