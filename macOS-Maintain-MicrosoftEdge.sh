#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-MicrosoftEdge.sh
# Description:    Unified Detect & Patch script for Microsoft Edge via Intune.
#                 Parses Microsoft's redirect headers for zero-bandwidth updates.
# ==============================================================================

APP_NAME="Microsoft Edge.app"
APP_PATH="/Applications/$APP_NAME"

# Official Microsoft Edge enterprise update API (returns JSON for all channels/platforms).
# NOTE: The old go.microsoft.com/fwlink/?linkid=2093438 endpoint now redirects to an
# Android .apk ("edge_arm_stable_*_Tencent.apk"), so the version regex never matched
# and every run aborted with "Could not parse version formatting strings". The API
# below is the documented, stable source for the latest macOS Stable PKG.
EDGE_API_URL="https://edgeupdates.microsoft.com/api/products?view=enterprise"

TEMP_DIR=$(mktemp -d "/private/tmp/edge_update.XXXXXX") || { echo "[FATAL] Could not create a private temporary directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
PKG_NAME="MicrosoftEdgeEnterprise.pkg"

# Apple Developer Team ID for Microsoft Corporation. The downloaded PKG must be
# signed by this team or we refuse to install it (defends against MITM / CDN tampering).
EXPECTED_TEAMID="UBF8T346G9"

echo "[START] Evaluating Microsoft Edge update endpoints..."

# ------------------------------------------------------------------------------
# PHASE 1: VERSION DISCOVERY VIA OFFICIAL ENTERPRISE UPDATE API
# ------------------------------------------------------------------------------
echo "[INFO] Querying Microsoft Edge enterprise update API..."

# Pull the channel manifest. macOS Stable PKGs are named "MicrosoftEdge-<ver>.pkg"
# (Beta/Dev carry a word before the dash, e.g. MicrosoftEdgeBeta-...), so anchoring on
# "MicrosoftEdge-<digit>" cleanly isolates the Stable channel without a JSON parser.
EDGE_JSON=$(curl -fsSL --proto '=https' --proto-redir '=https' "$EDGE_API_URL" --connect-timeout 10 --max-time 30)

if [ -z "$EDGE_JSON" ]; then
    echo "[WARN] Unable to reach Microsoft Edge update API. Skipping run."
    exit 0
fi

# Highest Stable macOS version across all listed releases (sort -V = version-aware sort).
VENDOR_VERSION=$(echo "$EDGE_JSON" \
    | grep -oE 'MicrosoftEdge-[0-9.]+\.pkg' \
    | sed -E 's/MicrosoftEdge-//; s/\.pkg//' \
    | sort -V | tail -n1)

if [ -z "$VENDOR_VERSION" ]; then
    echo "[WARN] Could not parse a Stable macOS version from the update API response. Skipping run."
    exit 0
fi

# Direct CDN download URL for that exact version.
FINAL_URL=$(echo "$EDGE_JSON" \
    | grep -oE "https://[^\"]*/MicrosoftEdge-${VENDOR_VERSION}\.pkg" \
    | head -n1)

if [ -z "$FINAL_URL" ]; then
    echo "[WARN] Resolved version $VENDOR_VERSION but found no matching download URL. Skipping run."
    exit 0
fi

echo "[INFO] Latest Version Live on Vendor CDN: $VENDOR_VERSION"


# ------------------------------------------------------------------------------
# PHASE 2: LOCAL AUDIT & VERSION COMPARISON
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString")
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Microsoft Edge is up-to-date. Closing session with zero network drag."
        exit 0
    fi
    echo "[OUTDATED] System version ($LOCAL_VERSION) lags behind stable release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] Microsoft Edge is missing from this workstation. Queueing base deployment."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF BROWSER WINDOWS ARE ACTIVE
# ------------------------------------------------------------------------------
if pgrep -x "Microsoft Edge" > /dev/null; then
    echo "[DEFERRED] Microsoft Edge browser framework is actively processing user windows."
    echo "[DEFERRED] Postponing patch rollout to prevent data loss or crashing active user tabs."
    # Exit 0 registers compliance for the current window and evaluates again on the next schedule
    exit 0
fi

echo "[CLEAR] No active process streams mapped. Proceeding safely to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & SILENT INSTALLATION OVERLAY
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    echo "[PROCEEDING] Creating scratch space and pulling down direct target installer payload..."
    mkdir -p "$TEMP_DIR"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --proto '=https' --proto-redir '=https' --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$FINAL_URL" -o "$TEMP_DIR/$PKG_NAME")

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "[FATAL] Download failed from Microsoft endpoints with HTTP status: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: confirm the PKG is signed by Microsoft before installing as root.
    if ! /usr/sbin/pkgutil --check-signature "$TEMP_DIR/$PKG_NAME" 2>/dev/null | grep -q "($EXPECTED_TEAMID)"; then
        echo "[FATAL] Signature/Team ID verification failed (expected $EXPECTED_TEAMID). Refusing to install."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] PKG signature verified (Team ID $EXPECTED_TEAMID)."

    echo "[INFO] Overwriting older core packages via native system installer tool..."
    if /usr/sbin/installer -pkg "$TEMP_DIR/$PKG_NAME" -target /; then
        echo "[SUCCESS] Microsoft Edge successfully deployed/upgraded to version $VENDOR_VERSION."
        rm -rf "$TEMP_DIR"
        exit 0
    else
        echo "[ERROR] Native installer framework encountered structural failures compiling binary stream."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
fi

exit 0
