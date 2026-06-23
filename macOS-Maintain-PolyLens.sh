#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-PolyLens.sh
# Description:    Unified Detect & Patch script for Poly Lens Desktop via Intune.
#                 Resolves the live installer via Poly's software-update GraphQL
#                 API and installs the PKG carried inside the vendor DMG.
# ==============================================================================

# Note: Poly Lens is being rebranded to "HP Poly Studio.app". Both bundle names are
# checked so version detection keeps working across the transition.
APP_CANDIDATES=("/Applications/Poly Lens.app" "/Applications/HP Poly Studio.app")

# Local database tracker (records the last version we installed) to minimize WAN use.
TRACKER_PLIST="/Library/Preferences/com.company.patching.polylens.plist"
TEMP_DIR="/private/tmp/poly_update"
DMG_PATH="$TEMP_DIR/PolyLens.dmg"

# Poly software-update GraphQL endpoint. The old static
# swupdate.lens.poly.com/lens-desktop-mac/latest/PolyLens.dmg path now 404s;
# this API returns the current version plus a versioned archive URL.
# Apple Developer Team ID for Plantronics/Poly. The PKG inside the DMG must match.
EXPECTED_TEAMID="WJCM3F7AQ4"

POLY_API="https://api.silica-prod01.io.lens.poly.com/graphql"
POLY_QUERY='{"operationName":"LensSoftwareUpdateAvailable","variables":{"productId":"lens-desktop-mac","releaseChannel":null},"query":"query LensSoftwareUpdateAvailable($productId: ID!, $releaseChannel: String) {availableProductSoftwareByPid(pid: $productId, releaseChannel: $releaseChannel) {version productBuild {build archiveUrl __typename} __typename}}"}'

echo "[START] Interrogating Poly cloud update infrastructure..."

# ------------------------------------------------------------------------------
# PHASE 1: RESOLVE LIVE VERSION + DOWNLOAD URL VIA API
# ------------------------------------------------------------------------------
POLY_JSON=$(curl -fsS "$POLY_API" -X POST -H 'Content-Type: application/json' \
    --data-raw "$POLY_QUERY" --connect-timeout 10 --max-time 30)

if [ -z "$POLY_JSON" ]; then
    echo "[WARN] Poly update API is unreachable. Skipping cycle to prevent disruption."
    exit 0
fi

VENDOR_VERSION=$(echo "$POLY_JSON" | grep -oE '"version":"[^"]+"' | head -n1 | cut -d'"' -f4)
DOWNLOAD_URL=$(echo "$POLY_JSON" | grep -oE '"archiveUrl":"[^"]+"' | head -n1 | cut -d'"' -f4)

if [ -z "$VENDOR_VERSION" ] || [ -z "$DOWNLOAD_URL" ]; then
    echo "[WARN] Could not parse version/URL from Poly API response. Skipping run."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"

# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
INSTALLED_PATH=""
for c in "${APP_CANDIDATES[@]}"; do
    if [ -d "$c" ]; then INSTALLED_PATH="$c"; break; fi
done

if [ -n "$INSTALLED_PATH" ] && [ -f "$TRACKER_PLIST" ]; then
    LOCAL_RECORDED_VERSION=$(defaults read "$TRACKER_PLIST" "LastVersion" 2>/dev/null)

    if [ "$VENDOR_VERSION" = "$LOCAL_RECORDED_VERSION" ]; then
        echo "[COMPLIANT] Poly Lens is already up-to-date ($VENDOR_VERSION). Exiting with ZERO download."
        exit 0
    fi
    echo "[OUTDATED] Tracked version ($LOCAL_RECORDED_VERSION) differs from vendor ($VENDOR_VERSION)."
else
    echo "[MISSING] Poly Lens app bundle not found. Forcing full download pipeline."
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF POLY LENS CORE PROCESSES ARE ACTIVE
# ------------------------------------------------------------------------------
echo "[INFO] Scanning active system processes for hardware routing dependencies..."

if pgrep -f "Poly Lens" > /dev/null || pgrep -f "PolyLens" > /dev/null || pgrep -f "Poly Studio" > /dev/null; then
    echo "[DEFERRED] Poly Lens app or background agent is actively managing devices."
    echo "[DEFERRED] Postponing upgrade to prevent active audio or HID call controls from dropping."
    # Exit 0 keeps the Intune console status clean and retries on the next schedule loop
    exit 0
fi

echo "[CLEAR] Environment safe. Proposing deployment orchestration phase..."


# ------------------------------------------------------------------------------
# PHASE 3: DOWNLOAD DMG & INSTALL THE PKG CARRIED INSIDE IT
# ------------------------------------------------------------------------------
mkdir -p "$TEMP_DIR"

HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$DMG_PATH")

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "[FATAL] Download failed with unexpected HTTP Network Token: $HTTP_STATUS"
    rm -rf "$TEMP_DIR"
    exit 1
fi

echo "[INFO] Mounting Poly Lens installer package container..."
MOUNT_POINT=$(hdiutil attach -nobrowse -readonly "$DMG_PATH" | grep -E '/Volumes/.*' | awk -F'\t' '{print $NF}' | head -n 1)

if [ -z "$MOUNT_POINT" ]; then
    echo "[FATAL] Mount sequence failed for the downloaded DMG."
    rm -rf "$TEMP_DIR"
    exit 1
fi

# The DMG carries a .pkg (not a drag-install .app), so locate and run it.
PKG_FILE=$(find "$MOUNT_POINT" -maxdepth 2 -name "*.pkg" -type f | head -n 1)

if [ -z "$PKG_FILE" ]; then
    echo "[FATAL] No .pkg installer found inside the mounted DMG volume."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi

# SECURITY: confirm the PKG is signed by Poly before installing as root.
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
    echo "[SUCCESS] Poly Lens deployed/upgraded to version $VENDOR_VERSION."

    # ------------------------------------------------------------------------------
    # PHASE 5: UPDATE THE LOCAL TRACKER DATABASE
    # ------------------------------------------------------------------------------
    echo "[DATABASE] Logging installed version for subsequent script runs..."
    defaults write "$TRACKER_PLIST" "LastVersion" "$VENDOR_VERSION"
    chmod 644 "$TRACKER_PLIST"
else
    echo "[ERROR] Native installer framework failed to apply the PKG payload."
    hdiutil detach "$MOUNT_POINT" -force
    rm -rf "$TEMP_DIR"
    exit 1
fi


# ------------------------------------------------------------------------------
# PHASE 6: POST-EXECUTION CLEANUP
# ------------------------------------------------------------------------------
echo "[INFO] Detaching disk volume and purging local cache configurations..."
hdiutil detach "$MOUNT_POINT" -force
rm -rf "$TEMP_DIR"

echo "[FINISH] Poly Lens update loop completed successfully."
exit 0
