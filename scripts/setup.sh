#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIBRARIES_DIR="$PROJECT_DIR/Libraries"
RESOURCES_DIR="$PROJECT_DIR/Resources"

echo "=== Ranunculus Setup ==="
echo "Project directory: $PROJECT_DIR"
echo ""

# --- Step 1: Get libvosk.dylib ---
LIBVOSK="$LIBRARIES_DIR/libvosk.dylib"
if [ -f "$LIBVOSK" ]; then
    # スタブライブラリ（~51KB）と本物（10MB+）をサイズで判別
    FILE_SIZE=$(stat -f%z "$LIBVOSK")
    if [ "$FILE_SIZE" -gt 1000000 ]; then
        echo "[OK] libvosk.dylib already exists ($(( FILE_SIZE / 1024 / 1024 ))MB)"
    else
        echo "[WARN] libvosk.dylib appears to be the stub (${FILE_SIZE} bytes). Re-downloading..."
        rm "$LIBVOSK"
    fi
fi

if [ ! -f "$LIBVOSK" ]; then
    echo "[1/3] Downloading VOSK library..."

    PYPI_INDEX="https://pypi-proxy.dev.databricks.com/simple/"
    TMPDIR_VOSK=$(mktemp -d)

    # uv を優先、なければ python3 -m venv + pip にフォールバック
    if command -v uv &>/dev/null; then
        uv venv "$TMPDIR_VOSK/venv"
        uv pip install --python "$TMPDIR_VOSK/venv/bin/python3" \
            --default-index "$PYPI_INDEX" vosk
    else
        python3 -m venv "$TMPDIR_VOSK/venv" 2>/dev/null || {
            python3 -m venv --without-pip "$TMPDIR_VOSK/venv"
            curl -sS https://bootstrap.pypa.io/get-pip.py | "$TMPDIR_VOSK/venv/bin/python3"
        }
        "$TMPDIR_VOSK/venv/bin/pip" install --index-url "$PYPI_INDEX" vosk
    fi

    # Find and copy the dylib
    VOSK_DIR=$("$TMPDIR_VOSK/venv/bin/python3" -c "import vosk, os; print(os.path.dirname(vosk.__file__))")

    if [ -f "$VOSK_DIR/libvosk.dylib" ]; then
        cp "$VOSK_DIR/libvosk.dylib" "$LIBRARIES_DIR/"
    elif [ -f "$VOSK_DIR/libvosk.dyld" ]; then
        cp "$VOSK_DIR/libvosk.dyld" "$LIBRARIES_DIR/libvosk.dylib"
    elif [ -f "$VOSK_DIR/libvosk.so" ]; then
        cp "$VOSK_DIR/libvosk.so" "$LIBRARIES_DIR/libvosk.dylib"
    else
        FOUND=$(find "$VOSK_DIR" -name "libvosk.*" | head -1)
        if [ -n "$FOUND" ]; then
            cp "$FOUND" "$LIBRARIES_DIR/libvosk.dylib"
        else
            echo "[ERROR] Could not find libvosk shared library in $VOSK_DIR"
            echo "Contents:"
            ls -la "$VOSK_DIR"
            rm -rf "$TMPDIR_VOSK"
            exit 1
        fi
    fi

    rm -rf "$TMPDIR_VOSK"

    # install name を @rpath/libvosk.dylib に設定（dyld が rpath 経由で検索できるようにする）
    install_name_tool -id "@rpath/libvosk.dylib" "$LIBRARIES_DIR/libvosk.dylib"

    # Ad-hoc code sign
    codesign --force --sign - "$LIBRARIES_DIR/libvosk.dylib"

    echo "[OK] libvosk.dylib installed"
fi

# Verify architecture
echo ""
echo "Library architecture:"
file "$LIBRARIES_DIR/libvosk.dylib"
echo ""

# --- Step 2: Download VOSK Japanese model ---
MODEL_NAME="vosk-model-small-ja-0.22"
MODEL_DIR="$RESOURCES_DIR/$MODEL_NAME"

if [ -d "$MODEL_DIR" ]; then
    echo "[OK] VOSK model already exists at $MODEL_DIR"
else
    echo "[2/3] Downloading VOSK Japanese model ($MODEL_NAME)..."
    TMPDIR_MODEL=$(mktemp -d)

    curl -L -o "$TMPDIR_MODEL/$MODEL_NAME.zip" \
        "https://alphacephei.com/vosk/models/$MODEL_NAME.zip"

    echo "Extracting model..."
    unzip -q "$TMPDIR_MODEL/$MODEL_NAME.zip" -d "$RESOURCES_DIR/"
    rm -rf "$TMPDIR_MODEL"

    echo "[OK] Model installed at $MODEL_DIR"
fi

# --- Step 3: Verify setup ---
echo ""
echo "[3/3] Verifying setup..."
echo ""

ERRORS=0

if [ ! -f "$LIBRARIES_DIR/libvosk.dylib" ]; then
    echo "[ERROR] libvosk.dylib not found"
    ERRORS=$((ERRORS + 1))
fi

if [ ! -d "$MODEL_DIR" ]; then
    echo "[ERROR] VOSK model not found at $MODEL_DIR"
    ERRORS=$((ERRORS + 1))
fi

if [ $ERRORS -eq 0 ]; then
    echo "=== Setup Complete ==="
    echo ""
    echo "Next steps:"
    echo "  cd $PROJECT_DIR"
    echo "  swift build"
    echo "  bash scripts/build-app.sh"
    echo ""
else
    echo "=== Setup failed with $ERRORS error(s) ==="
    exit 1
fi
