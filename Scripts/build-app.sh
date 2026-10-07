#!/bin/bash
#
# build-app.sh <version>
#
# Builds the release binary with SwiftPM and assembles "dist/Claude Profiles.app":
#   Contents/MacOS/ClaudeProfilesApp      (SwiftPM executable)
#   Contents/Info.plist                   (Resources/Info.plist with __VERSION__ filled in)
#   Contents/Resources/
#   Contents/Frameworks/Sparkle.framework (copied from the resolved Sparkle xcframework)
# then ad-hoc signs the outer app and writes dist/Claude.Profiles-<version>.zip, which is
# the archive Sparkle downloads for updates (see Scripts/make-appcast.sh).
#
# Used locally and by .github/workflows/release.yml.

set -euo pipefail

# --- Arguments -------------------------------------------------------------
if [[ $# -ne 1 || -z "$1" ]]; then
    echo "usage: $0 <version>   (e.g. $0 1.0.0)" >&2
    exit 64
fi
VERSION="$1"
# CFBundleVersion and CFBundleShortVersionString both receive this string, and Sparkle
# compares CFBundleVersion, so only plain dotted numbers are accepted.
if [[ ! "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]]; then
    echo "error: version must look like 1.2.3 (got '$VERSION')" >&2
    exit 64
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_ROOT="$PROJECT_ROOT/.build"
DIST="$PROJECT_ROOT/dist"
APP_BUNDLE="$DIST/Claude Profiles.app"
CONTENTS="$APP_BUNDLE/Contents"
EXECUTABLE="$CONTENTS/MacOS/ClaudeProfilesApp"
OUTPUT_ZIP="$DIST/Claude.Profiles-$VERSION.zip"
# Location of the macOS slice inside the binary artifact SwiftPM downloads for Sparkle
# (confirmed with `find .build/artifacts -name Sparkle.framework` for Sparkle 2.10.0).
SPARKLE_FRAMEWORK="$BUILD_ROOT/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

# --- 1. Compile (universal) ------------------------------------------------
# Building for both architectures makes one download work on Apple silicon and Intel
# Macs, and keeps Sparkle's appcast free of a hardwareRequirements restriction.
# Multi-arch builds go through SwiftPM's Xcode build system, whose product directory
# differs between toolchains (.build/apple/... on older Xcode, .build/out/... on newer),
# so the path is always asked from SwiftPM with the same flags instead of hard-coded.
SWIFT_BUILD_ARGS=(-c release --arch arm64 --arch x86_64 --package-path "$PROJECT_ROOT" --scratch-path "$BUILD_ROOT")
swift build "${SWIFT_BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"

# lipo prints slices in fat-header order, so compare as a sorted set.
ARCHS="$(lipo -archs "$BIN_DIR/ClaudeProfilesApp")"
if [[ "$(tr ' ' '\n' <<<"$ARCHS" | sort | xargs)" != "arm64 x86_64" ]]; then
    echo "error: expected a universal (arm64 + x86_64) binary, got: $ARCHS" >&2
    exit 1
fi

if [[ ! -d "$SPARKLE_FRAMEWORK" ]]; then
    echo "error: Sparkle.framework not found at $SPARKLE_FRAMEWORK" >&2
    echo "       run 'swift package resolve' and check the artifact layout." >&2
    exit 1
fi

# --- 2. Assemble the bundle ------------------------------------------------
rm -rf "$APP_BUNDLE"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$CONTENTS/Frameworks"
cp "$BIN_DIR/ClaudeProfilesApp" "$EXECUTABLE"
chmod +x "$EXECUTABLE"
cp "$PROJECT_ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
# ditto preserves the framework's Versions/Current symlinks, permissions and the vendor
# code signature exactly, so the framework stays valid without re-signing.
ditto "$SPARKLE_FRAMEWORK" "$CONTENTS/Frameworks/Sparkle.framework"

# --- 2b. Strip build-machine rpaths ----------------------------------------
# The toolchain adds an absolute rpath into the local Xcode (".../XcodeDefault.xctoolchain/
# usr/lib/swift-x.y/macosx") for Swift back-deployment libraries. On macOS 13+ the Swift
# runtime ships in /usr/lib/swift, so the entry is unnecessary and only leaks the build
# machine's layout. A fat binary lists each LC_RPATH once per slice, hence `sort -u`:
# install_name_tool removes the path from every slice in one call and a second call for
# the same path would fail. This must happen before signing (it invalidates signatures).
list_rpaths() {
    otool -l "$1" | awk '/cmd LC_RPATH/ {getline; getline; print $2}' | sort -u
}
while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    install_name_tool -delete_rpath "$rpath" "$EXECUTABLE"
done < <(list_rpaths "$EXECUTABLE" | grep 'xctoolchain' || true)

EXPECTED_RPATHS="$(printf '%s\n' "/usr/lib/swift" "@executable_path/../Frameworks" "@loader_path" | sort -u)"
if [[ "$(list_rpaths "$EXECUTABLE")" != "$EXPECTED_RPATHS" ]]; then
    echo "error: unexpected LC_RPATH set:" >&2
    list_rpaths "$EXECUTABLE" >&2
    exit 1
fi

# --- 3. Fill in the version ------------------------------------------------
plutil -replace CFBundleShortVersionString -string "$VERSION" "$CONTENTS/Info.plist"
plutil -replace CFBundleVersion -string "$VERSION" "$CONTENTS/Info.plist"

# --- 4. Sign (ad-hoc) and verify ------------------------------------------
# Extended attributes such as com.apple.FinderInfo make codesign fail with
# "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$APP_BUNDLE"
# Only the outer app is signed. No --deep: Sparkle.framework and its helpers ship already
# signed and re-signing them is unnecessary. No "-o runtime": with an ad-hoc identity,
# Hardened Runtime's library validation would refuse to load Sparkle.framework.
codesign --force --sign - "$APP_BUNDLE"

if ! codesign --verify --deep --strict "$APP_BUNDLE"; then
    # Fallback only: re-sign the framework (still no --deep / no runtime), then the app.
    echo "warning: verification failed; re-signing Sparkle.framework ad-hoc" >&2
    codesign --force --sign - "$CONTENTS/Frameworks/Sparkle.framework"
    codesign --force --sign - "$APP_BUNDLE"
    codesign --verify --deep --strict "$APP_BUNDLE"
    echo "note: Sparkle.framework was re-signed" >&2
fi

# --- 5. Confirm the executable can find the embedded framework -------------
# Without this rpath dyld cannot resolve @rpath/Sparkle.framework and the app crashes at
# launch, so a missing rpath is a build failure rather than a runtime surprise.
if ! otool -l "$EXECUTABLE" | grep -A2 LC_RPATH | grep -q "@executable_path/../Frameworks"; then
    echo "error: LC_RPATH @executable_path/../Frameworks missing from $EXECUTABLE" >&2
    exit 1
fi
if ! otool -L "$EXECUTABLE" | grep -q "@rpath/Sparkle.framework"; then
    echo "error: $EXECUTABLE does not link @rpath/Sparkle.framework" >&2
    exit 1
fi

# --- 6. Update archive -----------------------------------------------------
# --keepParent puts "Claude Profiles.app" at the archive root (what Sparkle expects) and
# ditto keeps the framework symlinks that zip(1) would otherwise flatten.
rm -f "$OUTPUT_ZIP"
ditto -c -k --keepParent --norsrc "$APP_BUNDLE" "$OUTPUT_ZIP"

echo "$APP_BUNDLE"
echo "$OUTPUT_ZIP"
