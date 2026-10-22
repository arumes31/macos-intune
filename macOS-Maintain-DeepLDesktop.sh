#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-DeepL-Optimized.sh
# Description:    Unified Detect & Patch script for DeepL on macOS via Intune.
#                 Resolves the live version from DeepL's versioned download index.
# ==============================================================================

APP_NAME="DeepL.app"
APP_PATH="/Applications/$APP_NAME"

# Versioned download index. The vendor exposes paths like "26.6/14916780/DeepL.dmg",
# so we can read the real latest version instead of guessing from ETag churn
# (ETags rotate on CDN re-replication even when the binary is unchanged -> false updates).
INDEX_URL="https://appdownload.deepl.com/macos/"

# Apple Developer Team ID for DeepL SE. The mounted app must match before we copy it.
EXPECTED_TEAMID="4N8BGCG336"

# Dedicated local tracker for the installed version across runs.
# IMPORTANT: this is a PLAIN file under Application Support, NOT a plist in
# /Library/Preferences. Anything in /Library/Preferences is a cfprefsd-managed
# preference domain: writing to it directly with `defaults` "works", but cfprefsd
# later flushes its in-memory cache back over the file and silently drops the key,
# so the next run reads an empty LastVersion and needlessly re-installs every cycle.
# A flat file outside Preferences is immune to that and is read/written directly.
TRACKER_DIR="/Library/Application Support/CompanyPatching"
TRACKER_FILE="$TRACKER_DIR/deepl.version"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/deepl_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/DeepL.dmg"

echo "[START] Interrogating DeepL remote server assets..."

# ------------------------------------------------------------------------------
# PHASE 1: RESOLVE LATEST VERSION + DOWNLOAD URL FROM THE INDEX
# ------------------------------------------------------------------------------
# Each entry looks like "<major>.<minor>/<build>/DeepL.dmg"; sort by version then
# build and take the newest.
LATEST_PATH=$(curl -fsS "$INDEX_URL" --connect-timeout 10 --max-time 20 \
    | grep -oE '[0-9]+\.[0-9]+/[0-9]+/DeepL\.dmg' \
    | sort -t'/' -k1,1V -k2,2n | tail -n 1)

if [ -z "$LATEST_PATH" ]; then
    echo "[WARN] Could not resolve a version from the DeepL index. Skipping cycle."
    exit 0
fi

VENDOR_VERSION=$(echo "$LATEST_PATH" | awk -F'/' '{print $1 "." $2}')
DOWNLOAD_URL="${INDEX_URL}${LATEST_PATH}"
echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=true

if [ -d "$APP_PATH" ] && [ -f "$TRACKER_FILE" ]; then
    LOCAL_RECORDED_VERSION=$(cat "$TRACKER_FILE" 2>/dev/null)

    if [ "$VENDOR_VERSION" = "$LOCAL_RECORDED_VERSION" ]; then
        echo "[COMPLIANT] DeepL is already up-to-date ($VENDOR_VERSION). Exiting with ZERO download overhead."
        exit 0
    fi
    echo "[OUTDATED] Tracked version ($LOCAL_RECORDED_VERSION) differs from vendor ($VENDOR_VERSION)."
else
    echo "[MISSING] Target bundle is missing or tracker database is empty. Forcing full pull."
fi


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & UPDATE PIPELINE (Only fires if Phase 2 passes through)
# ------------------------------------------------------------------------------
echo "[PROCEEDING] Executing download pipeline for the new payload..."

HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$DMG_PATH")

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "[FATAL] Download failed with unexpected HTTP Network Token: $HTTP_STATUS"
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

# Gracefully terminate app to prevent system file locks during copy phase
killall "DeepL" 2>/dev/null
sleep 2

echo "[INFO] Committing fresh binaries to the filesystem..."
rm -rf "$APP_PATH"

if cp -R "$MOUNT_POINT/$APP_NAME" "/Applications/"; then
    echo "[SUCCESS] DeepL deployed successfully."
    
    # SECURITY: keep the bundle root-owned (as vendor pkgs install it). Handing it to
    # the console user would let them tamper with code other users and this script trust.
    chown -R root:wheel "$APP_PATH"
    
    # ------------------------------------------------------------------------------
    # PHASE 4: UPDATE THE LOCAL TRACKER DATABASE
    # ------------------------------------------------------------------------------
    echo "[DATABASE] Logging installed version for next evaluation run..."
    mkdir -p "$TRACKER_DIR"
    printf '%s\n' "$VENDOR_VERSION" > "$TRACKER_FILE"
    chmod 644 "$TRACKER_FILE" # Ensure readability
else
    echo "[ERROR] File system copy exception occurred during installation phase."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Post-Execution Cleanup
hdiutil detach "$MOUNT_POINT" -force
rm -rf "$TEMP_DIR"
echo "[FINISH] DeepL deployment processing complete."
exit 0