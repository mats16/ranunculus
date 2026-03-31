#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_NAME="Ranunculus"
APP_BUNDLE="$PROJECT_DIR/$APP_NAME.app"

echo "=== Building $APP_NAME ==="

# Step 1: Build with SPM
echo "[1/4] Compiling Swift sources..."
cd "$PROJECT_DIR"
swift build -c release 2>&1

BINARY="$BUILD_DIR/release/$APP_NAME"
if [ ! -f "$BINARY" ]; then
    # Try debug build if release fails
    echo "Release build not found, trying debug..."
    swift build 2>&1
    BINARY="$BUILD_DIR/debug/$APP_NAME"
fi

if [ ! -f "$BINARY" ]; then
    echo "[ERROR] Build failed - binary not found"
    exit 1
fi

echo "[OK] Build succeeded"

# Step 2: Create .app bundle
echo "[2/4] Creating app bundle..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$PROJECT_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/"

# Step 3: Copy libraries and resources
echo "[3/4] Copying libraries and resources..."

# Copy libvosk.dylib
if [ -f "$PROJECT_DIR/Libraries/libvosk.dylib" ]; then
    cp "$PROJECT_DIR/Libraries/libvosk.dylib" "$APP_BUNDLE/Contents/Frameworks/"

    # スタブライブラリでないことを確認
    DYLIB_SIZE=$(stat -f%z "$APP_BUNDLE/Contents/Frameworks/libvosk.dylib")
    if [ "$DYLIB_SIZE" -lt 1000000 ]; then
        echo "[ERROR] libvosk.dylib appears to be the stub (${DYLIB_SIZE} bytes). Run scripts/setup.sh first."
        exit 1
    fi

    # Fix dylib rpath in binary
    install_name_tool -add_rpath "@executable_path/../Frameworks" \
        "$APP_BUNDLE/Contents/MacOS/$APP_NAME" 2>/dev/null || true

    # Ad-hoc sign the dylib
    codesign --force --sign - "$APP_BUNDLE/Contents/Frameworks/libvosk.dylib" 2>/dev/null || true
else
    echo "[WARN] libvosk.dylib not found in Libraries/"
fi

# Copy VOSK model
MODEL_DIR="$PROJECT_DIR/Resources/vosk-model-small-ja-0.22"
if [ -d "$MODEL_DIR" ]; then
    cp -R "$MODEL_DIR" "$APP_BUNDLE/Contents/Resources/"
    echo "[OK] VOSK model copied to app bundle"
else
    echo "[WARN] VOSK model not found at $MODEL_DIR"
fi

# Step 4: Code sign the app
echo "[4/4] Code signing..."
codesign --force --deep --sign - "$APP_BUNDLE" 2>/dev/null || true

echo ""
echo "=== Build Complete ==="
echo "App bundle: $APP_BUNDLE"
echo ""
echo "To run:"
echo "  open $APP_BUNDLE"
echo ""
echo "Or run directly:"
echo "  $APP_BUNDLE/Contents/MacOS/$APP_NAME"
