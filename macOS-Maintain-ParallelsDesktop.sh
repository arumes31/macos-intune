#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-ParallelsDesktop.sh (Safe-Run Variant)
# Description:    Unified Detect & Patch script for Parallels Desktop via Intune.
#                 Skips updates cleanly if the app or a VM is actively running.
# ==============================================================================

APP_NAME="Parallels Desktop.app"
APP_PATH="/Applications/$APP_NAME"
# DOWNLOAD_URL is resolved at runtime from the update feed (see PHASE 1). The old
# www.parallels.com/directdownload/pd/ link now redirects to the small online
# web-installer stub ("Install Parallels Desktop.dmg", ~2 MB) which contains NO
# "Parallels Desktop.app" bundle, so the mount/bundle check below always failed.
DOWNLOAD_URL=""

# Apple Developer Team ID for Parallels International GmbH (also used for kext consent).
EXPECTED_TEAMID="4C6364ACXT"

# Major versions whose update feeds we scan to discover the latest release. Parallels
# moved to YEAR-ALIGNED majors (v26 == 2026), skipping 21-25, so a hardcoded list went
# stale and pinned us to the old v20. Instead scan legacy majors (19-20) plus every
# year-aligned major from 26 up to (current 2-digit year + 1) for early pre-releases.
# Missing years simply return no feed and are skipped; the highest build found wins.
PD_MAJORS="19 20 $(seq 26 $(( $(date +%y) + 1 )))"

TRACKER_PLIST="/Library/Preferences/com.company.patching.parallels.plist"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/parallels_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/ParallelsDesktop.dmg"

echo "[START] Interrogating Parallels remote asset parameters..."

# ------------------------------------------------------------------------------
# PHASE 1: RESOLVE LATEST VERSION FROM THE OFFICIAL UPDATE FEEDS
# ------------------------------------------------------------------------------
# The old approach used www.parallels.com/directdownload/pd/, which now redirects to a
# tiny online web-installer stub (no "Parallels Desktop.app" inside) and broke the mount.
# Each feed publishes the real full-app installer (with "Parallels Desktop.app" inside)
# via a <FilePath>...ParallelsDesktop-<ver>-<build>.dmg</FilePath> element. We read both
# the URL and the version straight from there, and keep whichever feed advertises the
# highest build. This replaces the directdownload stub that no longer ships the bundle.
VENDOR_VERSION=""
for maj in $PD_MAJORS; do
    feed=$(curl -fsS "https://update.parallels.com/desktop/v${maj}/parallels/parallels_updates.xml" --connect-timeout 10 --max-time 20 2>/dev/null)
    [ -z "$feed" ] && continue
    url=$(echo "$feed" | grep -oiE 'https?://[^<> "]+/ParallelsDesktop-[0-9.]+-[0-9]+\.dmg' | head -1)
    [ -z "$url" ] && continue
    # ParallelsDesktop-20.4.2-55999.dmg -> 20.4.2.55999 (dotted, so sort -V orders it)
    v=$(echo "$url" | grep -oE 'ParallelsDesktop-[0-9.]+-[0-9]+' | sed -E 's/ParallelsDesktop-//; s/-/./')
    [ -z "$v" ] && continue
    if [ -z "$VENDOR_VERSION" ] || [ "$(printf '%s\n%s\n' "$VENDOR_VERSION" "$v" | sort -V | tail -1)" = "$v" ]; then
        VENDOR_VERSION="$v"
        DOWNLOAD_URL="$url"
    fi
done

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[WARN] Could not resolve a full-app DMG from Parallels update feeds. Skipping cycle."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"
echo "[INFO] Resolved installer URL: $DOWNLOAD_URL"


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

# The full app DMG is ~205 MB; 900s was too tight on throttled/VPN'd managed Macs and
# truncated the transfer. Give it 30 min so slow links still complete the pull.
HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$DMG_PATH")

# Default to "000" so an empty / non-numeric value can never make the guard below
# error out and get silently treated as success. That bug let a failed download fall
# through to hdiutil with no file on disk, producing the misleading
# "hdiutil: attach failed - No such file or directory". Use string compare too.
HTTP_STATUS=${HTTP_STATUS:-000}
if [ "$HTTP_STATUS" != "200" ]; then
    echo "[FATAL] Download failed with unexpected HTTP Network Token: $HTTP_STATUS"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Confirm the payload actually landed and is plausibly the full installer. A missing
# file, the ~2 MB web-installer stub, or a truncated transfer would otherwise reach
# hdiutil and fail with a cryptic ENOENT / "image not recognized".
if [ ! -s "$DMG_PATH" ]; then
    echo "[FATAL] Download reported HTTP 200 but no file was written to $DMG_PATH. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

DMG_BYTES=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo 0)
if [ "$DMG_BYTES" -lt 52428800 ]; then   # < 50 MB: stub or truncated, not the ~205 MB full app
    echo "[FATAL] Downloaded DMG is only $DMG_BYTES bytes (expected ~205 MB). Likely truncated. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Validate the disk image structure before attaching, so a corrupt/partial file is
# reported plainly instead of as the misleading hdiutil ENOENT.
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