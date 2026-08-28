#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-AdobeCreativeCloud.sh
# Description:    Unified Detect & Patch script for Adobe Creative Cloud Desktop via Intune.
#                 Queries Adobe's config API for the latest version, constructs the
#                 download URL, and silently runs the installer carried inside the DMG.
# ==============================================================================

APP_NAME="Creative Cloud.app"
APP_PATH="/Applications/Utilities/Adobe Creative Cloud/ACC/$APP_NAME"
TEMP_DIR=$(mktemp -d "/private/tmp/adobe_cc_update.XXXXXX") || { echo "[FATAL] Could not create a private temporary directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
DMG_PATH="$TEMP_DIR/AdobeCreativeCloud.dmg"

# Apple Developer Team ID for Adobe Inc. The installer inside the DMG must match.
EXPECTED_TEAMID="JQ525L2MZD"

echo "[START] Interrogating Adobe cloud update infrastructure..."

# 1. Identify local system architecture and map it to Adobe's naming.
# Release assets use "macarm64" (ARM64) or "osx10" (Intel)
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ASSET_ARCH="macarm64"
else
    ASSET_ARCH="osx10"
fi
echo "[INFO] System Architecture detected: $ARCH (asset tag: $ASSET_ARCH)"

# Adobe Version Configuration Feed
API_URL="https://ffc-static-cdn.oobesaas.adobe.com/features/v3/${ASSET_ARCH}/ccdConfig.xml"

# ------------------------------------------------------------------------------
# PHASE 1: RESOLVE LIVE VERSION + DOWNLOAD URL VIA API
# ------------------------------------------------------------------------------
API_XML=$(curl -fsS --proto '=https' --proto-redir '=https' "$API_URL" --connect-timeout 10 --max-time 30)

if [ -z "$API_XML" ]; then
    echo "[WARN] Adobe Creative Cloud config API is unreachable. Skipping cycle."
    exit 0
fi

# Extract version from XML data (safely parsing the JSON string inside the <data> tags)
VENDOR_VERSION=$(echo "$API_XML" | grep -oE '"version"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4)

if [ -z "$VENDOR_VERSION" ]; then
    echo "[WARN] Could not parse version from Adobe API response. Skipping run."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"

# Extract fields to construct URL dynamically:
# VENDOR_VERSION = 6.10.0.252.3 -> MAJOR_MINOR_PATCH = 6.10.0, BUILD_FIELDS = 252.3, UNDERSCORES = 6_10_0_252_3
MAJOR_MINOR_PATCH=$(echo "$VENDOR_VERSION" | cut -d'.' -f1-3)
BUILD_FIELDS=$(echo "$VENDOR_VERSION" | cut -d'.' -f4-5)
DOTS_TO_UNDERSCORES=$(echo "$VENDOR_VERSION" | tr '.' '_')

DOWNLOAD_URL="https://ccmdls.adobe.com/AdobeProducts/StandaloneBuilds/ACCC/ESD/${MAJOR_MINOR_PATCH}/${BUILD_FIELDS}/${ASSET_ARCH}/ACCCx${DOTS_TO_UNDERSCORES}.dmg"


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString" 2>/dev/null)
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Adobe Creative Cloud is fully up to date. Closing session."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] Adobe Creative Cloud app bundle not found. Forcing full download pipeline."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF CREATIVE CLOUD IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -x "Creative Cloud" >/dev/null || pgrep -x "Adobe Desktop Service" >/dev/null; then
    echo "[DEFERRED] Adobe Creative Cloud Desktop process tree is active. Postponing upgrade to avoid data loss."
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: DOWNLOAD DMG & EXECUTE SILENT UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    mkdir -p "$TEMP_DIR"

    echo "[PROCEEDING] Downloading Adobe Creative Cloud DMG payload..."
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$DMG_PATH")

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
    if [ "$DMG_BYTES" -lt 52428800 ]; then   # < 50 MB: truncated download, not the ~311 MB full app
        echo "[FATAL] Downloaded DMG is only $DMG_BYTES bytes. Likely truncated. Aborting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    if ! hdiutil imageinfo "$DMG_PATH" >/dev/null 2>&1; then
        echo "[FATAL] Downloaded file is not a valid disk image. Aborting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    echo "[INFO] Mounting Adobe Creative Cloud installer package container ($DMG_BYTES bytes)..."
    ATTACH_OUT=$(yes 2>/dev/null | hdiutil attach -nobrowse -noverify -noautoopen -readonly "$DMG_PATH" 2>&1)
    ATTACH_RC=$?
    if [ "$ATTACH_RC" -ne 0 ]; then
        echo "[FATAL] hdiutil attach failed (rc=$ATTACH_RC): $ATTACH_OUT"
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    MOUNT_POINT=$(echo "$ATTACH_OUT" | grep -E '/Volumes/.*' | awk -F'\t' '{print $NF}' | head -n 1)

    if [ -z "$MOUNT_POINT" ] || [ ! -d "$MOUNT_POINT/Creative Cloud/Install.app" ]; then
        echo "[FATAL] Mount sequence failed or app bundle corrupt within DMG wrapper."
        [[ -n "$MOUNT_POINT" ]] && hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: verify the app signature + Team ID of the installer before running it
    if ! /usr/bin/codesign --verify --deep --strict "$MOUNT_POINT/Creative Cloud/Install.app" 2>/dev/null \
       || ! /usr/bin/codesign -dvv "$MOUNT_POINT/Creative Cloud/Install.app" 2>&1 | grep -q "TeamIdentifier=$EXPECTED_TEAMID"; then
        echo "[FATAL] Code signature / Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to run installer."
        hdiutil detach "$MOUNT_POINT" -force
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] Installer signature verified (Team ID $EXPECTED_TEAMID)."

    # ------------------------------------------------------------------------------
    # PHASE 4: SILENT EXECUTION OF NATIVE INSTALLER
    # ------------------------------------------------------------------------------
    echo "[INFO] Running native Adobe installer silently..."
    if "$MOUNT_POINT/Creative Cloud/Install.app/Contents/MacOS/Install" --mode=silent; then
        echo "[SUCCESS] Adobe Creative Cloud deployed/upgraded successfully to version $VENDOR_VERSION."
    else
        echo "[ERROR] Native installer framework returned a non-zero exit code."
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
fi

echo "[FINISH] Adobe Creative Cloud maintenance run completed."
exit 0
