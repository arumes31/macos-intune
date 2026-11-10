#!/bin/bash
# shellcheck disable=SC2016,SC2034  # check() evaluates its single-quoted assertions later
# Tests for macOS-Maintain-VLC.sh with stubbed curl/defaults/pgrep : the appcast is fetched over
# HTTPS only, an older feed version never triggers a downgrade, and a failed download (including an
# empty HTTP status) is fatal. Nothing is installed : every run stops before the DMG is mounted.
#
# usage : bash tests/vlc_update_test.sh

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FAILED=0

mkdir -p "$WORK/bin" "$WORK/VLC.app/Contents"
# the script under test, pointed at a fake installed bundle and a local scratch dir
sed -e "s|^APP_PATH=.*|APP_PATH=\"$WORK/VLC.app\"|" -e "s|/private/tmp/|$WORK/|" "$ROOT/macOS-Maintain-VLC.sh" > "$WORK/vlc.sh"

cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
echo "$*" >> "$STUB_LOG"
case "$*" in
    *sparkle*) printf '<rss><item><enclosure sparkle:version="1.1.3"/></item><item><enclosure sparkle:version="%s"/></item></rss>\n' "$FEED_VERSION" ;;
    *) printf '%s' "$DOWNLOAD_STATUS" ;;
esac
EOF
cat > "$WORK/bin/defaults" <<'EOF'
#!/bin/bash
echo "$LOCAL_VERSION"
EOF
cat > "$WORK/bin/pgrep" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$WORK/bin/"*

# run the script : $1 local version, $2 feed version, $3 HTTP status printed by the download
run() {
    : > "$WORK/curl.log"
    OUTPUT=$(PATH="$WORK/bin:$PATH" STUB_LOG="$WORK/curl.log" LOCAL_VERSION="$1" FEED_VERSION="$2" DOWNLOAD_STATUS="$3" bash "$WORK/vlc.sh" 2>&1)
    STATUS=$?
}

check() {
    if eval "$2"; then
        echo "ok   - $1"
    else
        echo "FAIL - $1"
        printf '%s\n' "$OUTPUT"
        FAILED=1
    fi
}

run 3.0.21 3.0.18 200
check "appcast fetched over https only" 'grep -q "=https" "$WORK/curl.log" && grep -q "https://update.videolan.org/" "$WORK/curl.log" && ! grep -q "http://" "$WORK/curl.log"'
check "older feed version does not downgrade" '[ "$STATUS" -eq 0 ] && [[ $OUTPUT == *"Refusing to downgrade"* ]] && ! grep -q "get.videolan.org" "$WORK/curl.log"'

run 3.0.21 3.0.21 200
check "same version is compliant" '[ "$STATUS" -eq 0 ] && [[ $OUTPUT == *"[COMPLIANT]"* ]] && ! grep -q "get.videolan.org" "$WORK/curl.log"'

run 3.0.18 3.0.21 404
check "newer feed version is downloaded" 'grep -q "https://get.videolan.org/vlc/3.0.21/macosx/" "$WORK/curl.log"'
check "failed download is fatal" '[ "$STATUS" -eq 1 ] && [[ $OUTPUT == *"Download failed"* ]]'

run 3.0.18 3.0.21 ""
check "empty HTTP status is fatal" '[ "$STATUS" -eq 1 ] && [[ $OUTPUT == *"Download failed"* ]]'

if [ "$FAILED" -ne 0 ]; then
    echo "some tests failed"
    exit 1
fi
echo "all tests passed"
