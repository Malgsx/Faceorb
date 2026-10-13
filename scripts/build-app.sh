#!/usr/bin/env bash
# Builds build/FaceOrb.app (menu bar only) on macOS 14+ with Xcode 16+ command line tools.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --open     build and launch
#   scripts/build-app.sh --clean    also delete the build cache (.build, ~1-2 GB) afterwards
set -euo pipefail
cd "$(dirname "$0")/.."

OPEN=0; CLEAN=0
for arg in "$@"; do
  case "$arg" in --open) OPEN=1 ;; --clean) CLEAN=1 ;; esac
done

# A full disk breaks builds and makes Finder fail with error -36, so check first.
FREE_KB=$(df -k . | awk 'NR==2 {print $4}')
echo "Free disk space: $((FREE_KB / 1024 / 1024)) GB"
if (( FREE_KB < 3 * 1024 * 1024 )); then
  echo "Less than 3 GB free. Free some space first (System Settings > General > Storage)." >&2
  exit 1
fi

MODEL=Resources/face_recognition_sface_2021dec.onnx
MODEL_URL=https://github.com/opencv/opencv_zoo/raw/main/models/face_recognition_sface/face_recognition_sface_2021dec.onnx
MODEL_SHA256=0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79

if [[ ! -f "$MODEL" ]]; then
  echo "Downloading SFace face model (Apache-2.0, 37 MB)…"
  curl -fL --progress-bar -o "$MODEL.tmp" "$MODEL_URL"
  mv "$MODEL.tmp" "$MODEL"
fi
echo "$MODEL_SHA256  $MODEL" | shasum -a 256 -c -

# Taken before compiling, so edits made during the build show up as a newer update.
SOURCE_VERSION=$(scripts/source-fingerprint.sh || true)
[[ -n "$SOURCE_VERSION" ]] || echo "Not a git checkout: the app's Update button will be hidden." >&2

# Command Line Tools without Xcode ship the macOS 27 SDK but not its SwiftUI macro plugin, so @State
# fails to expand. Fall back to the newest older SDK they include, whose SwiftUI doesn't need it.
DEV_DIR=$(xcode-select -p 2>/dev/null || true)
if [[ -z "${SDKROOT:-}" && "$DEV_DIR" == */CommandLineTools ]] \
   && ! compgen -G "$DEV_DIR/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null \
   && ! compgen -G "$(xcrun --show-sdk-path)/usr/lib/swift/host/plugins/*SwiftUIMacros*" >/dev/null; then
  FALLBACK_SDK=$(ls -d "$DEV_DIR"/SDKs/MacOSX26.*.sdk 2>/dev/null | sort -V | tail -1 || true)
  if [[ -n "$FALLBACK_SDK" ]]; then
    echo "No SwiftUI macro plugin in the Command Line Tools; building with $(basename "$FALLBACK_SDK")."
    export SDKROOT="$FALLBACK_SDK"
  fi
fi

swift build -c release --product FaceOrb
BIN="$(swift build -c release --show-bin-path)"

# Assembled next to the old app and swapped in at the end, so a failed build (or one started
# from the app's own Update button) never leaves you without a working app.
FINAL=build/FaceOrb.app
APP=build/FaceOrb.app.new
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN/FaceOrb" "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"
# Lets the app's "Update" button find this checkout and tell when it has changed.
if [[ -n "$SOURCE_VERSION" ]]; then
  plutil -insert FaceOrbSourceDir -string "$PWD" "$APP/Contents/Info.plist"
  plutil -insert FaceOrbSourceVersion -string "$SOURCE_VERSION" "$APP/Contents/Info.plist"
fi
cp "$MODEL" "$APP/Contents/Resources/"
cp -R "$BIN/FaceOrb_FaceOrbWeb.bundle" "$APP/Contents/Resources/"

# If ONNX Runtime came in as a dynamic framework, ship it inside the bundle.
shopt -s nullglob
for fw in "$BIN"/*.framework; do
  cp -R "$fw" "$APP/Contents/Frameworks/"
done
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/FaceOrb" 2>/dev/null || true

# Ad-hoc signature so macOS will run it locally. Use a Developer ID to distribute.
codesign --force --deep --sign - "$APP"
rm -rf "$FINAL.old"
[[ -e "$FINAL" ]] && mv "$FINAL" "$FINAL.old"
mv "$APP" "$FINAL"
rm -rf "$FINAL.old"
APP=$FINAL
echo "Built $APP"

if (( CLEAN )); then
  rm -rf .build
  echo "Removed the build cache."
fi

if (( OPEN )); then
  open "$APP"
fi
