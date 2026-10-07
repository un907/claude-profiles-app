#!/bin/bash
#
# make-appcast.sh <version>
#
# Generates dist/appcast.xml for one release with Sparkle's generate_appcast. The feed
# contains exactly one item: dist/Claude.Profiles-<version>.zip, signed with the EdDSA
# private key. Because the app's SUFeedURL points at
#   https://github.com/un907/claude-profiles-app/releases/latest/download/appcast.xml
# each release's own appcast is what clients see, so history does not need to be kept.
#
# Key source (never printed; do not add `set -x` to this script):
#   - $SPARKLE_PRIVATE_KEY if set (GitHub Actions secret), piped via --ed-key-file -
#   - otherwise the maintainer's login Keychain item for account "claude-profiles-app"

set -euo pipefail

if [[ $# -ne 1 || -z "$1" ]]; then
    echo "usage: $0 <version>   (e.g. $0 1.0.0)" >&2
    exit 64
fi
VERSION="$1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DIST="$PROJECT_ROOT/dist"
ZIP_NAME="Claude.Profiles-$VERSION.zip"
INPUT_DIR="$DIST/appcast-input"
OUTPUT="$DIST/appcast.xml"
DOWNLOAD_PREFIX="https://github.com/un907/claude-profiles-app/releases/download/v$VERSION/"
# Shipped inside the Sparkle SwiftPM binary artifact (confirmed for Sparkle 2.10.0).
GENERATE_APPCAST="$PROJECT_ROOT/.build/artifacts/sparkle/Sparkle/bin/generate_appcast"
KEYCHAIN_ACCOUNT="claude-profiles-app"

if [[ ! -x "$GENERATE_APPCAST" ]]; then
    echo "error: generate_appcast not found at $GENERATE_APPCAST (run swift package resolve)" >&2
    exit 1
fi
if [[ ! -f "$DIST/$ZIP_NAME" ]]; then
    echo "error: $DIST/$ZIP_NAME not found; run Scripts/build-app.sh $VERSION first" >&2
    exit 1
fi

# --- Prepare a clean input folder -----------------------------------------
# generate_appcast scans every archive in the folder and merges into an existing output
# file, so both are reset to guarantee a single-item feed for this version only (and no
# delta updates against stray older archives).
rm -rf "$INPUT_DIR"
rm -f "$OUTPUT"
mkdir -p "$INPUT_DIR"
cp "$DIST/$ZIP_NAME" "$INPUT_DIR/"

# --- Generate and sign -----------------------------------------------------
if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    # CI path: the key arrives via stdin so it never touches disk or argv.
    printf '%s\n' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" \
        --ed-key-file - \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        -o "$OUTPUT" \
        "$INPUT_DIR"
else
    # Local path: generate_appcast reads the key from the Keychain itself.
    "$GENERATE_APPCAST" \
        --account "$KEYCHAIN_ACCOUNT" \
        --download-url-prefix "$DOWNLOAD_PREFIX" \
        -o "$OUTPUT" \
        "$INPUT_DIR"
fi

# --- Validate --------------------------------------------------------------
# A feed without a signature would be rejected by every client, so fail the release here.
grep -q 'sparkle:edSignature' "$OUTPUT" || { echo "error: appcast has no sparkle:edSignature" >&2; exit 1; }
grep -q '<sparkle:version>' "$OUTPUT" || { echo "error: appcast has no <sparkle:version>" >&2; exit 1; }
grep -qF "$DOWNLOAD_PREFIX$ZIP_NAME" "$OUTPUT" || { echo "error: appcast enclosure URL is not $DOWNLOAD_PREFIX$ZIP_NAME" >&2; exit 1; }

echo "$OUTPUT"
