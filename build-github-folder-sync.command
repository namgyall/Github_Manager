#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-$SCRIPT_DIR/GITHUB_SYNC_BUILD}"
if [[ "$OUTPUT_DIR" != /* ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/$OUTPUT_DIR"
fi

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "This app can only be built on macOS 14 or later."
fi
MACOS_VERSION="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VERSION%%.*}"
if (( MACOS_MAJOR < 14 )); then
    fail "macOS 14 or later is required (found $MACOS_VERSION)."
fi
for tool in swiftc codesign plutil; do
    command -v "$tool" >/dev/null 2>&1 || fail "Required tool not found: $tool."
done

APP_NAME="Github Manager"
APP_PATH="$OUTPUT_DIR/$APP_NAME.app"
[[ ! -e "$APP_PATH" ]] || fail "Refusing to overwrite existing app bundle: $APP_PATH. Choose another OUTPUT_DIR."
mkdir -p "$OUTPUT_DIR"
STAGING_DIR="$(mktemp -d "$OUTPUT_DIR/.github-manager.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT

APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$SCRIPT_DIR/GitHubFolderSyncInfo.plist" "$CONTENTS/Info.plist"
plutil -lint "$CONTENTS/Info.plist" >/dev/null || fail "The app's Info.plist is invalid."
[[ -f "$SCRIPT_DIR/Resources/GithubManager.icns" ]] ||
    fail "App icon not found: $SCRIPT_DIR/Resources/GithubManager.icns."
cp "$SCRIPT_DIR/Resources/GithubManager.icns" "$CONTENTS/Resources/GithubManager.icns"

swiftc -parse-as-library -O "$SCRIPT_DIR/GitHubFolderSyncApp.swift" \
    -framework AppKit -framework SwiftUI -framework Security \
    -o "$CONTENTS/MacOS/$APP_NAME" ||
    fail "Compilation failed."
codesign --force --deep --sign - "$APP_BUNDLE" || fail "Ad-hoc code signing failed."
codesign --verify --deep --strict "$APP_BUNDLE" || fail "The built app did not pass signature verification."
mv -n -- "$APP_BUNDLE" "$APP_PATH" ||
    fail "Could not move the verified app into $OUTPUT_DIR."
[[ -d "$APP_PATH" ]] || fail "The app bundle was not installed."
printf 'Built and signed: %s\n' "$APP_PATH"
