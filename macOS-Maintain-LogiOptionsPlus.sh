#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-LogiOptionsPlus.sh
# Description:    Unified Detect & Patch script for Logi Options+ via Intune.
#                 Uses HTTP HEAD tracking and native silent installer arguments.
# ==============================================================================

APP_NAME="Logi Options+.app"
APP_PATH="/Applications/$APP_NAME"

# Official Logitech permanent redirect direct-download download pipeline URL
DOWNLOAD_URL="https://download01.logi.com/web/ftp/pub/techsupport/optionsplus/logioptionsplus_installer.zip"

# Apple Developer Team ID for Logitech Inc. The installer app is verified before running.
EXPECTED_TEAMID="QED4VVPZWA"

# NOTE: Logi Options+ has no reliable public version endpoint (the installer ZIP URL
# carries no version, and the Logitech support API is locale/OS-fragile), so this
# script keeps the ETag/Content-Length change check rather than a version comparison.

# Local system database storage tracker for zero-bandwidth loops
TRACKER_PLIST="/Library/Preferences/com.company.patching.logioptionsplus.plist"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/logi_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
ZIP_PATH="$TEMP_DIR/logioptionsplus_installer.zip"

echo "[START] Querying Logitech content delivery networks..."

# ------------------------------------------------------------------------------
# PHASE 1: LIGHTWEIGHT REMOTE METADATA ASSESSMENT
# ------------------------------------------------------------------------------
SERVER_HEADERS=$(curl -sSLI "$DOWNLOAD_URL" --connect-timeout 10 --max-time 15)

if [ -z "$SERVER_HEADERS" ]; then
    echo "[WARN] Logitech server infrastructure is unreachable. Skipping run."
    exit 0
fi

# Extract Content-Length (File Size) and ETag (Server Hash Verification)
REMOTE_SIZE=$(echo "$SERVER_HEADERS" | grep -Ei '^content-length:' | awk '{print $2}' | tr -d '\r' | tail -n 1)
REMOTE_ETAG=$(echo "$SERVER_HEADERS" | grep -Ei '^etag:' | awk '{print $2}' | tr -d '\r"' | tail -n 1)

if [ -z "$REMOTE_SIZE" ]; then
    echo "[WARN] Unable to extract valid server size variables. Skipping runtime check."
    exit 0
fi

echo "[INFO] Remote Payload Metrics -> Size: $REMOTE_SIZE bytes | ETag: $REMOTE_ETAG"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
if [ -d "$APP_PATH" ] && [ -f "$TRACKER_PLIST" ]; then
    LOCAL_RECORDED_SIZE=$(defaults read "$TRACKER_PLIST" "LastContentLength" 2>/dev/null)
    LOCAL_RECORDED_ETAG=$(defaults read "$TRACKER_PLIST" "LastETag" 2>/dev/null)
    
    # If size and hash match perfectly, the software hasn't changed
    if [ "$REMOTE_SIZE" = "$LOCAL_RECORDED_SIZE" ] && [ "$REMOTE_ETAG" = "$LOCAL_RECORDED_ETAG" ]; then
        echo "[COMPLIANT] ETag and Content-Length match our database signatures."
        echo "[COMPLIANT] Logi Options+ is completely current. Closing session with ZERO downloads."
        exit 0
    fi
    echo "[OUTDATED] Hardware software update is available."
else
    echo "[MISSING] Logi Options+ app bundle not found. Forcing deployment sequence."
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF APPLICATION IS ACTIVE
# ------------------------------------------------------------------------------
echo "[INFO] Verifying peripheral background app states..."

# Check if the user is currently using the control panel or if background tracking is running
if pgrep -f "Logi Options+" > /dev/null || pgrep -f "logioptionsplus" > /dev/null; then
    echo "[DEFERRED] Logi Options+ or its driver daemon is actively mapping devices."
    echo "[DEFERRED] Postponing upgrade to prevent custom peripheral shortcuts from crashing."
    # Exit 0 tells Intune to mark the loop cycle successful and re-evaluate on the next schedule
    exit 0
fi

echo "[CLEAR] Environment safe. Proceeding with download sequence."


# ------------------------------------------------------------------------------
# PHASE 3: RETRIEVE PAYLOAD & DECOMPRESS
# ------------------------------------------------------------------------------

# 600s was too tight on throttled/VPN'd managed Macs and truncated the transfer; give
# slow links 30 min to finish the pull.
HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$ZIP_PATH")

# Default to "000" so an empty / non-numeric value can never make the guard below
# error out (integer compare) and get silently treated as success. Use string compare.
HTTP_STATUS=${HTTP_STATUS:-000}
if [ "$HTTP_STATUS" != "200" ]; then
    echo "[FATAL] Download pipeline failed with network token error: $HTTP_STATUS"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Confirm the payload actually landed on disk.
if [ ! -s "$ZIP_PATH" ]; then
    echo "[FATAL] Download reported HTTP 200 but no file was written to $ZIP_PATH. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Verify archive integrity before inflating. A truncated transfer (slow/VPN'd link)
# would otherwise reach the find below and surface as a confusing "missing installer
# layout" error instead of a clear "download incomplete" message. (-t is also race-free:
# a complete-but-newer ZIP passes and installs as intended.)
if ! unzip -tqq "$ZIP_PATH" >/dev/null 2>&1; then
    echo "[FATAL] Downloaded ZIP failed integrity test (corrupt or partial transfer). Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "[INFO] Inflating zip container..."
unzip -q -o "$ZIP_PATH" -d "$TEMP_DIR"

# macOS-built zips carry a __MACOSX/ folder of AppleDouble resource-fork stubs that
# mirror the real tree, including a fake "__MACOSX/logioptionsplus_installer.app" with
# no executable inside. Drop it so the find below can't latch onto the stub and then
# fail with "No such file or directory" when running the installer binary.
rm -rf "$TEMP_DIR/__MACOSX"

# Locate the app installer wrapper unzipped inside the folder (never under __MACOSX).
INSTALLER_APP=$(find "$TEMP_DIR" -name "logioptionsplus_installer.app" -type d -not -path '*/__MACOSX/*' | head -n 1)

if [ -z "$INSTALLER_APP" ] || [ ! -d "$INSTALLER_APP" ]; then
    echo "[FATAL] Failed to unpack a valid logioptionsplus_installer.app package layout."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# SECURITY: verify the installer app's signature + Team ID before executing it as root.
if ! /usr/bin/codesign --verify --deep --strict "$INSTALLER_APP" 2>/dev/null \
   || ! /usr/bin/codesign -dvv "$INSTALLER_APP" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
    echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to run installer."
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "[SECURITY] Installer signature verified (Team ID $EXPECTED_TEAMID)."


# ------------------------------------------------------------------------------
# PHASE 4: EXECUTE SILENT ENTERPRISE UPGRADE
# ------------------------------------------------------------------------------
echo "[INFO] Launching native Logitech silent setup binary..."

# Enforce quiet parameter loops and strip analytics out for corporate compliance
"$INSTALLER_APP/Contents/MacOS/logioptionsplus_installer" --quiet --analytics No --sso No --flow Yes
INSTALL_STATUS=$?

if [ $INSTALL_STATUS -eq 0 ]; then
    echo "[SUCCESS] Logitech installer framework applied configurations successfully."
    
    # ------------------------------------------------------------------------------
    # PHASE 5: UPDATE THE DATABASE TRACKER
    # ------------------------------------------------------------------------------
    echo "[DATABASE] Writing new hashes to local system log arrays..."
    defaults write "$TRACKER_PLIST" "LastContentLength" "$REMOTE_SIZE"
    defaults write "$TRACKER_PLIST" "LastETag" "$REMOTE_ETAG"
    chmod 644 "$TRACKER_PLIST"
else
    echo "[FATAL] Logitech installer execution engine faulted out with exit code: $INSTALL_STATUS"
    rm -rf "$TEMP_DIR"
    exit 1
fi


# ------------------------------------------------------------------------------
# PHASE 6: POST-EXECUTION CLEANUP
# ------------------------------------------------------------------------------
echo "[INFO] Cleansing scratch environments..."
rm -rf "$TEMP_DIR"

echo "[FINISH] Logi Options+ automated lifecycle run completed."
exit 0