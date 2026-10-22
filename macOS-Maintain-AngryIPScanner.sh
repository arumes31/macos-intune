#!/bin/bash
# ==============================================================================
# Script Name:    Maintain-AngryIPScanner.sh
# Description:    Unified Detect & Patch script for Angry IP Scanner on macOS via Intune.
#                 Queries GitHub API for the latest version, downloads the
#                 architecture-specific ZIP, extracts and installs the application.
# ==============================================================================

APP_NAME="Angry IP Scanner.app"
APP_PATH="/Applications/$APP_NAME"
# SECURITY: create a private (root-owned, 0700) scratch dir with an unpredictable name.
# A fixed /private/tmp path could be pre-created or symlinked by a standard user to
# swap the payload between signature verification and the root install.
TEMP_DIR=$(mktemp -d "/private/tmp/angryip_update.XXXXXX") || { echo "[FATAL] Unable to create private scratch directory."; exit 1; }
trap 'rm -rf "$TEMP_DIR"' EXIT
ZIP_PATH="$TEMP_DIR/angryip.zip"

# Angry IP Scanner macOS builds are unsigned, so integrity is checked by SHA-256 instead.
# By default the ZIP must match the digest GitHub computed when the asset was uploaded
# (published in the release API). For stronger assurance, set this to the SHA-256 of a
# release ZIP you have vetted: only that exact build will then be installed.
PINNED_SHA256=""

# Only accept downloads from the official project's GitHub release assets.
EXPECTED_URL_PREFIX="https://github.com/angryip/ipscan/releases/download/"

echo "[START] Initiating Angry IP Scanner version alignment assessment..."

# 1. Identify local system architecture and map it to Angry IP Scanner's asset naming.
# Release assets are named "ipscan-macArm64-<version>.zip" / "ipscan-macX86-<version>.zip"
ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
    ASSET_ARCH="macArm64"
else
    ASSET_ARCH="macX86"
fi
echo "[INFO] System Architecture detected: $ARCH (asset tag: $ASSET_ARCH)"

# ------------------------------------------------------------------------------
# PHASE 1: ZERO-DOWNLOAD API VERSION CHECK
# ------------------------------------------------------------------------------
echo "[INFO] Fetching metadata from latest stable GitHub release..."
RELEASE_JSON=$(curl -sL "https://api.github.com/repos/angryip/ipscan/releases/latest")

if [ -z "$RELEASE_JSON" ]; then
    echo "[WARN] Unable to reach GitHub API. Skipping patch cycle to preserve network."
    exit 0
fi

# Extract target production version string safely without requiring jq
VENDOR_VERSION=$(echo "$RELEASE_JSON" | grep -m 1 '"tag_name":' | sed -E 's/.*"tag_name":[[:space:]]*"v?([^"]+)".*/\1/')
echo "[INFO] Latest Version Released by Vendor: $VENDOR_VERSION"

# Dynamically parse the download link for this architecture.
DOWNLOAD_URL=$(echo "$RELEASE_JSON" | grep -o '"browser_download_url": "[^"]*' | grep -i "$ASSET_ARCH" | head -n 1 | awk -F '"' '{print $4}')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[FATAL] Script failed to isolate a valid installer URL payload."
    exit 1
fi

case "$DOWNLOAD_URL" in
    "$EXPECTED_URL_PREFIX"*) ;;
    *)
        echo "[FATAL] Download URL is not an official angryip/ipscan release asset: $DOWNLOAD_URL"
        exit 1
        ;;
esac

# GitHub-computed digest of the selected asset ("digest" precedes "browser_download_url"
# inside each asset object; reset on every new asset so digests can't leak across assets).
ASSET_SHA256=$(echo "$RELEASE_JSON" | awk -v url="$DOWNLOAD_URL" '
    /"url":[[:space:]]*"https:\/\/api\.github\.com\/repos\/[^"]*\/releases\/assets\// { d = "" }
    /"digest":/ { if (match($0, /sha256:[0-9a-fA-F]+/)) d = substr($0, RSTART + 7, RLENGTH - 7) }
    index($0, "\"browser_download_url\": \"" url "\"") { print d; exit }')

EXPECTED_SHA256="${PINNED_SHA256:-$ASSET_SHA256}"
if [ -z "$EXPECTED_SHA256" ]; then
    echo "[FATAL] No SHA-256 available for this asset (no GitHub digest and no PINNED_SHA256). Refusing to install."
    exit 1
fi


# ------------------------------------------------------------------------------
# PHASE 2: EVALUATE VERSION DRIFT
# ------------------------------------------------------------------------------
PROCEED_INSTALL=false

if [ -d "$APP_PATH" ]; then
    LOCAL_VERSION=$(defaults read "$APP_PATH/Contents/Info.plist" "CFBundleShortVersionString" 2>/dev/null)
    echo "[INFO] Current Local Version Installed: $LOCAL_VERSION"
    
    if [ "$LOCAL_VERSION" = "$VENDOR_VERSION" ]; then
        echo "[COMPLIANT] Angry IP Scanner is fully up to date. Exiting with zero network consumption."
        exit 0
    fi
    echo "[OUTDATED] Local copy ($LOCAL_VERSION) is older than vendor release ($VENDOR_VERSION)."
    PROCEED_INSTALL=true
else
    echo "[MISSING] Angry IP Scanner is not installed on this endpoint. Forcing initialization."
    PROCEED_INSTALL=true
fi


# ------------------------------------------------------------------------------
# SAFETY CHECK: DEFER IF ANGRY IP SCANNER IS ACTIVELY RUNNING
# ------------------------------------------------------------------------------
if pgrep -f "Angry IP Scanner" >/dev/null || pgrep -x "ipscan" >/dev/null; then
    echo "[DEFERRED] Angry IP Scanner process tree is active. Postponing upgrade to avoid data loss."
    exit 0
fi

echo "[CLEAR] System processes clear. Proceeding to remediation."


# ------------------------------------------------------------------------------
# PHASE 3: REMEDIATION & IN-PLACE UPGRADE
# ------------------------------------------------------------------------------
if [ "$PROCEED_INSTALL" = true ]; then
    echo "[PROCEEDING] Downloading payload from URL: $DOWNLOAD_URL"
    
    HTTP_STATUS=$(curl -L -s -w "%{http_code}" --retry 3 --retry-delay 5 --connect-timeout 15 --max-time 600 "$DOWNLOAD_URL" -o "$ZIP_PATH")

    if [ "$HTTP_STATUS" -ne 200 ]; then
        echo "[FATAL] Download failed with unexpected HTTP Status: $HTTP_STATUS"
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # SECURITY: verify the payload hash before touching its contents.
    ACTUAL_SHA256=$(shasum -a 256 "$ZIP_PATH" | awk '{print $1}')
    if [ "$(echo "$ACTUAL_SHA256" | tr 'A-F' 'a-f')" != "$(echo "$EXPECTED_SHA256" | tr 'A-F' 'a-f')" ]; then
        echo "[FATAL] SHA-256 mismatch (expected $EXPECTED_SHA256, got $ACTUAL_SHA256). Refusing to install."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    echo "[SECURITY] Payload SHA-256 verified: $ACTUAL_SHA256"

    # Verify ZIP integrity
    if ! unzip -tqq "$ZIP_PATH" >/dev/null 2>&1; then
        echo "[FATAL] Downloaded ZIP failed integrity test. Aborting."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    echo "[INFO] Inflating zip container..."
    unzip -q -o "$ZIP_PATH" -d "$TEMP_DIR"
    rm -rf "$TEMP_DIR/__MACOSX"

    # Locate the unzipped app bundle
    UNZIPPED_APP=$(find "$TEMP_DIR" -name "Angry IP Scanner.app" -type d -not -path '*/__MACOSX/*' | head -n 1)

    if [ -z "$UNZIPPED_APP" ] || [ ! -d "$UNZIPPED_APP" ]; then
        echo "[FATAL] Failed to unpack a valid Angry IP Scanner.app bundle."
        rm -rf "$TEMP_DIR"
        exit 1
    fi

    # Note: Angry IP Scanner macOS builds are currently unsigned by the vendor,
    # so codesign/Team ID validation is replaced by the SHA-256 check above.
    echo "[SECURITY] Skipping codesign check (vendor package is unsigned; SHA-256 verified)."

    echo "[INFO] Overwriting older binaries in /Applications..."
    rm -rf "$APP_PATH"
    
    if cp -R "$UNZIPPED_APP" "/Applications/"; then
        echo "[SUCCESS] Angry IP Scanner bundle written successfully."
        
        # De-quarantine so Gatekeeper doesn't block first launch
        echo "[SECURITY] De-quarantining the application bundle..."
        xattr -rd com.apple.quarantine "$APP_PATH" 2>/dev/null
        
        # SECURITY: keep the bundle root-owned (as vendor pkgs install it). Handing it to
        # the console user would let them tamper with code other users and this script trust.
        chown -R root:wheel "$APP_PATH"
    else
        echo "[ERROR] Copy failure from extracted ZIP to destination drive."
        rm -rf "$TEMP_DIR"
        exit 1
    fi
    
    # Cleanup environments
    rm -rf "$TEMP_DIR"
fi

echo "[FINISH] Angry IP Scanner maintenance run completed."
exit 0
