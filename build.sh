#!/usr/bin/env bash
#
# Build and package deceiverMe.app (universal binary by default).
#
# Environment:
#   BUILD_STYLE=universal|native   (default: universal — Intel + Apple Silicon, macOS 11+)
#   SKIP_CODESIGN=1                Skip ad-hoc codesign step
#   SKIP_ZIP=1                     Do not create dist/deceiverMe-macos.zip
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="deceiverMe.app"
APP_DIR="${SCRIPT_DIR}/${APP_NAME}"
SWIFT_FILE="${SCRIPT_DIR}/MouseMoverNative/MouseMoverNative.swift"
EXECUTABLE_NAME="MouseMoverNative"
EXECUTABLE="${APP_DIR}/Contents/MacOS/${EXECUTABLE_NAME}"
PACKAGING="${SCRIPT_DIR}/packaging"
DIST_DIR="${SCRIPT_DIR}/dist"

BUILD_STYLE="${BUILD_STYLE:-universal}"
SKIP_CODESIGN="${SKIP_CODESIGN:-0}"
SKIP_ZIP="${SKIP_ZIP:-0}"

SDK="$(xcrun --show-sdk-path --sdk macosx)"

# Release-style binary: optimized, suitable for distribution zips.
SWIFTC_RELEASE_FLAGS=(
  -O
  -whole-module-optimization
)

FRAMEWORKS=(
  -framework Cocoa
  -framework CoreGraphics
  -framework Carbon
  -framework UserNotifications
  -framework IOKit
)

compile() {
  local target="$1"
  local output="$2"
  echo "  → swiftc $target → $(basename "$output")"
  swiftc "${SWIFTC_RELEASE_FLAGS[@]}" \
    -o "$output" \
    -target "$target" \
    -sdk "$SDK" \
    "$SWIFT_FILE" \
    "${FRAMEWORKS[@]}"
}

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  deceiverMe — build"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  BUILD_STYLE=${BUILD_STYLE}"
echo "  SKIP_CODESIGN=${SKIP_CODESIGN}  SKIP_ZIP=${SKIP_ZIP}"
echo ""

if ! command -v swiftc &>/dev/null; then
  echo "Error: swiftc not found. Install Xcode Command Line Tools:"
  echo "  xcode-select --install"
  exit 1
fi

if [[ ! -f "$SWIFT_FILE" ]]; then
  echo "Error: missing source: $SWIFT_FILE"
  exit 1
fi

if [[ ! -f "$PACKAGING/Info.plist" ]]; then
  echo "Error: missing ${PACKAGING}/Info.plist"
  exit 1
fi

mkdir -p "${APP_DIR}/Contents/MacOS"
mkdir -p "${APP_DIR}/Contents/Resources"
mkdir -p "$DIST_DIR"

cp -f "${PACKAGING}/Info.plist" "${APP_DIR}/Contents/Info.plist"
# PkgInfo: exactly 8 bytes — bundle type APPL + creator (legacy)
printf 'APPL????' > "${APP_DIR}/Contents/PkgInfo"

echo "Compiling…"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ "$BUILD_STYLE" == "universal" ]]; then
  MIN_VER="11.0"
  X86_OUT="${TMP_DIR}/${EXECUTABLE_NAME}.x86_64"
  ARM_OUT="${TMP_DIR}/${EXECUTABLE_NAME}.arm64"
  set +e
  compile "x86_64-apple-macosx${MIN_VER}" "$X86_OUT"
  X86_OK=$?
  compile "arm64-apple-macosx${MIN_VER}" "$ARM_OUT"
  ARM_OK=$?
  set -e
  if [[ $X86_OK -eq 0 && $ARM_OK -eq 0 ]]; then
    echo "  → lipo (universal binary)"
    lipo -create -output "$EXECUTABLE" "$X86_OUT" "$ARM_OUT"
  else
    echo ""
    echo "Warning: universal build failed (x86 exit:$X86_OK arm exit:$ARM_OK)."
    echo "         Falling back to native single-arch for this machine."
    BUILD_STYLE="native"
  fi
fi

if [[ "$BUILD_STYLE" == "native" ]]; then
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64) TARGET="arm64-apple-macosx11.0" ;;
    x86_64) TARGET="x86_64-apple-macosx10.13" ;;
    *)
      echo "Error: unsupported architecture: $ARCH"
      exit 1
      ;;
  esac
  compile "$TARGET" "$EXECUTABLE"
  if [[ "$ARCH" == "x86_64" ]]; then
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 10.13" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
  else
    /usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion 11.0" "${APP_DIR}/Contents/Info.plist" 2>/dev/null || true
  fi
fi

if [[ ! -f "$EXECUTABLE" || ! -s "$EXECUTABLE" ]]; then
  echo "Error: executable missing or empty: $EXECUTABLE"
  exit 1
fi

chmod 755 "$EXECUTABLE"

echo ""
if [[ "$SKIP_CODESIGN" == "1" ]]; then
  echo "Skipping codesign (SKIP_CODESIGN=1)."
elif command -v codesign &>/dev/null; then
  echo "Codesigning (ad-hoc)…"
  if codesign --force --deep --sign - "$APP_DIR"; then
    if codesign --verify --verbose=2 "$APP_DIR" 2>&1; then
      : # verify output printed above
    fi
  else
    echo "Error: codesign failed (see messages above). Fix signing or use SKIP_CODESIGN=1."
    exit 1
  fi
else
  echo "Warning: codesign not in PATH; bundle left unsigned. Install Xcode CLT or set SKIP_CODESIGN=1."
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  OK — ${APP_NAME}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
file "$EXECUTABLE" | sed 's/^/  /'
echo ""

if [[ "$SKIP_ZIP" != "1" ]]; then
  ZIP_PATH="${DIST_DIR}/deceiverMe-macos.zip"
  rm -f "$ZIP_PATH"
  (cd "$SCRIPT_DIR" && ditto -c -k --sequesterRsrc --keepParent "$APP_NAME" "$ZIP_PATH")
  if [[ ! -f "$ZIP_PATH" || ! -s "$ZIP_PATH" ]]; then
    echo "Error: zip was not created: $ZIP_PATH"
    exit 1
  fi
  echo "  Archive:  $ZIP_PATH"
  echo ""
fi

echo "  Install:  open \"$APP_DIR\""
echo "  Or copy:  cp -R \"$APP_DIR\" /Applications/"
echo ""
