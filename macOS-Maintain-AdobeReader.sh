#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-AdobeReader.sh
# Description:    Unified Detect & Patch script for Adobe Acrobat Reader via Intune.
#                 Queries Adobe's RDC API for the latest version, constructs the
#                 download URL, and installs the PKG carried inside the DMG.
# ==============================================================================

APP_CANDIDATES=("/Applications/Adobe Acrobat Reader.app" "/Applications/Adobe Acrobat Reader DC.app")
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/adobe_reader_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/AdobeReader.dmg"

# Apple Developer Team ID for Adobe Inc. The PKG inside the DMG must match.
EXPECTED_TEAMID="JQ525L2MZD"

# Adobe RDC Version Feed API
API_URL="https://rdc.adobe.io/reader/products?lang=en&site=landing&os=Mac%20OS%2012.0&api_key=dc-get-adobereader-cdn"

echo "[START] Interrogating Adobe cloud update infrastructure..."

# ------------------------------------------------------------------------------
# PHASE 1: RESOLVE LIVE VERSION + DOWNLOAD URL VIA API
# ------------------------------------------------------------------------------
API_JSON=$(curl -fsS "$API_URL" --connect-timeout 10 --max-time 30)

if [ -z "$API_JSON" ]; then
    echo "[WARN] Adobe update API is unreachable. Skipping cycle to prevent disruption."
    exit 0
fi

# Parse version from JSON
VENDOR_VERSION=$(echo "$API_JSON" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)

if [ -z "$VENDOR_VERSION" ]; then
    echo "[WARN] Could not parse version from Adobe API response. Skipping run."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"

# Construct the download URL using the version string with dots removed
VERSION_NO_DOTS=$(echo "$VENDOR_VERSION" | tr -d '.')
DOWNLOAD_URL="https://ardownload2.adobe.com/pub/adobe/reader/mac/AcrobatDC/${VERSION_NO_DOTS}/AcroRdrDC_${VERSION_NO_DOTS}_MUI.dmg"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
INSTALLED_PATH=""
for c in "${APP_CANDIDATES[@]}"; do
    if [ -d "$c" ]; then
        INSTALLED_PATH="$c"
        break
    fi
done

if [ -n "$INSTALLED_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$INSTALLED_PATH/Contents/Info.plist" "CFBundleShortVersionString" 2>/dev/null)
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Adobe Acrobat Reader is fully up to date. Closing session with zero data waste."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
else
    echo "[MISSING] Adobe Acrobat Reader app bundle not found. Forcing full download pipeline."
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF ADOBE READER IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -x "Adobe Acrobat Reader" >/dev/null || pgrep -x "Adobe Acrobat" >/dev/null; then
    echo "[DEFERRED] Adobe Acrobat or Reader process tree is active. Postponing upgrade to avoid closing user documents."
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: DOWNLOAD DMG & INSTALL THE PKG CARRIED INSIDE IT
# ------------------------------------------------------------------------------

# Adobe Reader universal installer DMG is ~713 MB; give slow links 45 min to finish.
echo "[PROCEEDING] Downloading Adobe Acrobat Reader DMG payload (~713 MB)..."
HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 2700 "$DOWNLOAD_URL" -o "$DMG_PATH")

HTTP_STATUS=${HTTP_STATUS:-000}
if [ "$HTTP_STATUS" != "200" ]; then
    echo "[FATAL] Download failed with unexpected HTTP Status: $HTTP_STATUS"
    rm -rf "$TEMP_DIR"
    exit 1
fi

if [ ! -s "$DMG_PATH" ]; then
    echo "[FATAL] Download reported HTTP 200 but no file was written to $DMG_PATH. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

DMG_BYTES=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo 0)
if [ "$DMG_BYTES" -lt 104857600 ]; then   # < 100 MB: truncated download, not the ~713 MB full app
    echo "[FATAL] Downloaded DMG is only $DMG_BYTES bytes (expected ~713 MB). Likely truncated. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

if ! hdiutil imageinfo "$DMG_PATH" >/dev/null 2>&1; then
    echo "[FATAL] Downloaded file is not a valid disk image (corrupt or partial transfer). Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "[INFO] Mounting Adobe Reader installer package container ($DMG_BYTES bytes)..."
ATTACH_OUT=$(yes 2>/dev/null | hdiutil attach -nobrowse -noverify -noautoopen -readonly "$DMG_PATH" 2>&1)
ATTACH_RC=$?
if [ "$ATTACH_RC" -ne 0 ]; then
    echo "[FATAL] hdiutil attach failed (rc=$ATTACH_RC): $ATTACH_OUT"
    rm -rf "$TEMP_DIR"
    exit 1
fi
MOUNT_POINT=$(echo "$ATTACH_OUT" | grep -E '/Volumes/.*' | awk -F'\t' '{print $NF}' | head -n 1)

if [ -z "$MOUNT_POINT" ]; then
    echo "[FATAL] Mount sequence failed for the downloaded DMG."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Locate the PKG inside the mounted DMG
PKG_FILE=$(find "$MOUNT_POINT" -maxdepth 2 -name "*.pkg" -type f | head -n 1)

if [ -z "$PKG_FILE" ]; then
    echo "[FATAL] No .pkg installer found inside the mounted DMG volume."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi

# SECURITY: confirm the PKG is signed by Adobe before installing as root.
if ! /usr/sbin/pkgutil --check-signature "$PKG_FILE" 2>/dev/null | grep -q "($EXPECTED_TEAMID)"; then
    echo "[FATAL] Signature/Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi
echo "[SECURITY] PKG signature verified (Team ID $EXPECTED_TEAMID)."


# ------------------------------------------------------------------------------
# PHASE 4: SILENT INSTALL VIA NATIVE INSTALLER
# ------------------------------------------------------------------------------
echo "[INFO] Installing $(basename "$PKG_FILE") via native system installer..."
if /usr/sbin/installer -pkg "$PKG_FILE" -target /; then
    echo "[SUCCESS] Adobe Acrobat Reader deployed/upgraded successfully to version $VENDOR_VERSION."
else
    echo "[ERROR] Native installer framework failed to apply the PKG payload."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi


# ------------------------------------------------------------------------------
# PHASE 5: POST-EXECUTION CLEANUP
# ------------------------------------------------------------------------------
echo "[INFO] Detaching disk volume and purging local cache..."
hdiutil detach "$MOUNT_POINT" -force
rm -rf "$TEMP_DIR"

echo "[FINISH] Adobe Acrobat Reader maintenance run completed."
exit 0
