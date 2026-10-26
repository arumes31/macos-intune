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

# Local tracker (records the last version we installed) to minimize WAN use.
# IMPORTANT: a PLAIN file under Application Support, NOT a plist in /Library/Preferences.
# Files in /Library/Preferences are cfprefsd-managed preference domains: writing to them
# directly with `defaults` "works", but cfprefsd later flushes its in-memory cache back
# over the file and silently drops the key, so the next run reads an empty LastVersion
# and needlessly re-installs every cycle. A flat file outside Preferences is immune.
TRACKER_DIR="/Library/Application Support/CompanyPatching"
TRACKER_FILE="$TRACKER_DIR/polylens.version"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/poly_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
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

if [ -n "$INSTALLED_PATH" ] && [ -f "$TRACKER_FILE" ]; then
    LOCAL_RECORDED_VERSION=$(cat "$TRACKER_FILE" 2>/dev/null)

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

# The DMG is ~225 MB; 600s was too tight on throttled/VPN'd managed Macs and truncated
# the transfer. A truncated DMG loses its trailing "koly" block, which is exactly what
# makes hdiutil report "image not recognized". Give slow links 30 min to finish.
HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 1800 "$DOWNLOAD_URL" -o "$DMG_PATH")

# Default to "000" so an empty / non-numeric value can never make the guard below
# error out (integer compare) and get silently treated as success. Use string compare.
HTTP_STATUS=${HTTP_STATUS:-000}
if [ "$HTTP_STATUS" != "200" ]; then
    echo "[FATAL] Download failed with unexpected HTTP Network Token: $HTTP_STATUS"
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Confirm the payload landed and is plausibly the full installer.
if [ ! -s "$DMG_PATH" ]; then
    echo "[FATAL] Download reported HTTP 200 but no file was written to $DMG_PATH. Aborting."
    rm -rf "$TEMP_DIR"
    exit 1
fi

DMG_BYTES=$(stat -f%z "$DMG_PATH" 2>/dev/null || echo 0)
if [ "$DMG_BYTES" -lt 52428800 ]; then   # < 50 MB: truncated download, not the ~225 MB full app
    echo "[FATAL] Downloaded DMG is only $DMG_BYTES bytes (expected ~225 MB). Likely truncated. Aborting."
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

echo "[INFO] Mounting Poly Lens installer package container ($DMG_BYTES bytes)..."
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
    mkdir -p "$TRACKER_DIR"
    printf '%s\n' "$VENDOR_VERSION" > "$TRACKER_FILE"
    chmod 644 "$TRACKER_FILE"
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
