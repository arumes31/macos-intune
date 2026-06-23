#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-ParallelsDesktop.sh (Safe-Run Variant)
# Description:    Unified Detect & Patch script for Parallels Desktop via Intune.
#                 Skips updates cleanly if the app or a VM is actively running.
# ==============================================================================

APP_NAME="Parallels Desktop.app"
APP_PATH="/Applications/$APP_NAME"
DOWNLOAD_URL="https://www.parallels.com/directdownload/pd/"

# Apple Developer Team ID for Parallels International GmbH (also used for kext consent).
EXPECTED_TEAMID="4C6364ACXT"

# Major versions whose update feeds we scan to discover the latest release. Add the
# next major here when Parallels ships it; the script picks the highest version found.
PD_MAJORS="19 20 21 22"

TRACKER_PLIST="/Library/Preferences/com.company.patching.parallels.plist"
TEMP_DIR="/private/tmp/parallels_update"
DMG_PATH="$TEMP_DIR/ParallelsDesktop.dmg"

echo "[START] Interrogating Parallels remote asset parameters..."

# ------------------------------------------------------------------------------
# PHASE 1: RESOLVE LATEST VERSION FROM THE OFFICIAL UPDATE FEEDS
# ------------------------------------------------------------------------------
# The old approach tracked the directdownload stub's ETag, which rotates on CDN
# re-replication and triggered needless reinstalls. Instead, read the real version
# from update.parallels.com and keep the directdownload URL (it always serves latest).
VENDOR_VERSION=""
for maj in $PD_MAJORS; do
    feed=$(curl -fsS "https://update.parallels.com/desktop/v${maj}/parallels/parallels_updates.xml" --connect-timeout 10 --max-time 20 2>/dev/null)
    [ -z "$feed" ] && continue
    MA=$(echo "$feed" | grep -oiE '<Major>[0-9]+'       | head -1 | grep -oE '[0-9]+')
    MI=$(echo "$feed" | grep -oiE '<Minor>[0-9]+'       | head -1 | grep -oE '[0-9]+')
    SM=$(echo "$feed" | grep -oiE '<SubMinor>[0-9]+'    | head -1 | grep -oE '[0-9]+')
    SS=$(echo "$feed" | grep -oiE '<SubSubMinor>[0-9]+' | head -1 | grep -oE '[0-9]+')
    [ -z "$MA" ] && continue
    v="${MA}.${MI}.${SM}.${SS}"
    VENDOR_VERSION=$(printf '%s\n%s\n' "$VENDOR_VERSION" "$v" | grep -v '^$' | sort -V | tail -1)
done

if [ -z "$VENDOR_VERSION" ]; then
    echo "[WARN] Could not resolve a version from Parallels update feeds. Skipping cycle."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
if [ -d "$APP_PATH" ] && [ -f "$TRACKER_PLIST" ]; then
    LOCAL_RECORDED_VERSION=$(defaults read "$TRACKER_PLIST" "LastVersion" 2>/dev/null)

    if [ "$VENDOR_VERSION" = "$LOCAL_RECORDED_VERSION" ]; then
        echo "[COMPLIANT] Parallels is already up-to-date ($VENDOR_VERSION). Exiting immediately."
        exit 0
    fi
    echo "[OUTDATED] Tracked version ($LOCAL_RECORDED_VERSION) differs from vendor ($VENDOR_VERSION)."
else
    echo "[MISSING] Target bundle is missing or tracker database is empty. Forcing pull."
fi


# ------------------------------------------------------------------------------
# NEW: SAFETY CHECK - IS PARALLELS ACTIVELY RUNNING?
# ------------------------------------------------------------------------------
echo "[INFO] Auditing local process tree for active Parallels environments..."

# Check for the GUI app or the hypervisor core handling a running VM
if pgrep -x "Parallels Desktop" > /dev/null || pgrep -x "prl_vm_app" > /dev/null; then
    echo "[DEFERRED] Parallels Desktop or an active Virtual Machine is currently running."
    echo "[DEFERRED] Postponing upgrade execution to protect user data from corruption."
    # Exit 0 keeps the Intune console green and retries during the next execution schedule
    exit 0
fi

echo "[CLEAR] No active Parallels processes detected. Proceeding safely to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & ZIP/DMG ORCHESTRATION
# ------------------------------------------------------------------------------
echo "[PROCEEDING] Starting download pipeline for new Parallels payload..."
mkdir -p "$TEMP_DIR"

HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 900 "$DOWNLOAD_URL" -o "$DMG_PATH")

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

# SECURITY: verify the signature + Team ID of the app in the DMG before running inittool.
if ! /usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/$APP_NAME" 2>/dev/null \
   || ! /usr/bin/codesign -dvv "$MOUNT_POINT/$APP_NAME" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
    echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "[SECURITY] App signature verified (Team ID $EXPECTED_TEAMID)."


# ------------------------------------------------------------------------------
# PHASE 4: NATIVE ENFORCED INSTALLATION VIA INITTOOL
# ------------------------------------------------------------------------------
echo "[INFO] Flushing residual background helper tools..."
killall "prlctl" 2>/dev/null
killall "prl_client_app" 2>/dev/null
sleep 2

echo "[INFO] Invoking native Parallels inittool installer framework..."
"$MOUNT_POINT/$APP_NAME/Contents/MacOS/inittool" install -t "$APP_PATH" -s
INIT_STATUS=$?

if [ $INIT_STATUS -eq 0 ] && [ -d "$APP_PATH" ]; then
    echo "[SUCCESS] Core installer stream executed cleanly."
    
    echo "[INFO] Starting postflight environment initialization bootstrap..."
    "$APP_PATH/Contents/MacOS/inittool" init -b "$APP_PATH"
    
    # ------------------------------------------------------------------------------
    # PHASE 5: UPDATE THE TRACKER DATABASE
    # ------------------------------------------------------------------------------
    echo "[DATABASE] Logging installed version for next evaluation run..."
    defaults write "$TRACKER_PLIST" "LastVersion" "$VENDOR_VERSION"
    chmod 644 "$TRACKER_PLIST"
else
    echo "[FATAL] Native installer framework returned an error code: $INIT_STATUS"
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi


# ------------------------------------------------------------------------------
# PHASE 6: POST-EXECUTION CLEANUP
# ------------------------------------------------------------------------------
echo "[INFO] Detaching disk volume and purging temporary cache folder..."
hdiutil detach "$MOUNT_POINT" -force
rm -rf "$TEMP_DIR"

echo "[FINISH] Parallels patch processing completed successfully."
exit 0