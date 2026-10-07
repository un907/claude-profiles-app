#!/bin/bash
#
# make-dmg.sh <version>
#
# Packages the already-built "dist/Claude Profiles.app" (Scripts/build-app.sh) into
# dist/Claude.Profiles-<version>.dmg for first-time installs: the volume contains the app
# and an "Applications" symlink so users can drag-install. Only hdiutil is used so the
# release pipeline needs no third-party tools. Updates use the ZIP, not this DMG.

set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "usage: $0 <version>   (e.g. $0 1.0.0)" >&2
    exit 64
fi
VERSION="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST/Claude Profiles.app"
OUTPUT_DMG="$DIST/Claude.Profiles-$VERSION.dmg"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "error: $APP_BUNDLE not found; run Scripts/build-app.sh $VERSION first" >&2
    exit 1
fi

# --- Stage the volume contents --------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/claude-profiles-dmg.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto "$APP_BUNDLE" "$STAGE/Claude Profiles.app"
ln -s /Applications "$STAGE/Applications"

# --- Create the image ------------------------------------------------------
# ULFO (lzfse) is smaller and supported on macOS 10.11+, which covers our 13.0 minimum.
# Fall back to UDZO (zlib) on hosts whose hdiutil rejects ULFO.
rm -f "$OUTPUT_DMG"
if ! hdiutil create -volname "Claude Profiles" -srcfolder "$STAGE" -ov -format ULFO "$OUTPUT_DMG"; then
    echo "warning: ULFO failed; retrying with UDZO" >&2
    rm -f "$OUTPUT_DMG"
    hdiutil create -volname "Claude Profiles" -srcfolder "$STAGE" -ov -format UDZO "$OUTPUT_DMG"
fi

echo "$OUTPUT_DMG"
