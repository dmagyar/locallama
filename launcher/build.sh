#!/bin/bash
set -euo pipefail

# Build script for ollama-local Windows composite binary
# Usage: ./build.sh [model.gguf]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_FILE="${1:-${SCRIPT_DIR}/../build/gemma-2-2b-it-Q4_K_M.gguf}"
OUTPUT="${SCRIPT_DIR}/../build/ollama-local.exe"
TEMP_BIN="${SCRIPT_DIR}/../build/ollama-local-base.exe"

# Helper: convert bytes to MB (integer)
to_mb() {
    python3 -c "print(f'{$1/1048576:.1f}')"
}

echo "============================================"
echo "  Ollama Local - Windows Composite Builder"
echo "============================================"
echo ""

# Check prerequisites
if ! command -v go &> /dev/null; then
    echo "ERROR: Go is not installed"
    exit 1
fi

if ! command -v x86_64-w64-mingw32-gcc &> /dev/null; then
    echo "ERROR: mingw-w64 cross-compiler is not installed"
    echo "  Install with: sudo apt install mingw-w64"
    exit 1
fi

# Check model file
if [ ! -f "${MODEL_FILE}" ]; then
    echo "ERROR: Model file not found: ${MODEL_FILE}"
    echo "Usage: $0 [path/to/model.gguf]"
    exit 1
fi

MODEL_SIZE=$(stat -c%s "${MODEL_FILE}")
MODEL_HASH=$(sha256sum "${MODEL_FILE}" | cut -d' ' -f1)
echo "Model: ${MODEL_FILE}"
echo "  Size: $(to_mb ${MODEL_SIZE}) MB"
echo "  SHA256: ${MODEL_HASH}"
echo ""

# Check embedded llama-server
if [ ! -f "${SCRIPT_DIR}/embedded/llama-server.exe" ]; then
    echo "ERROR: Embedded llama-server.exe not found"
    echo "  Build llama-server first and place it in embedded/"
    exit 1
fi

SERVER_SIZE=$(stat -c%s "${SCRIPT_DIR}/embedded/llama-server.exe")
echo "llama-server.exe: $(to_mb ${SERVER_SIZE}) MB (embedded)"
echo ""

# Step 1: Cross-compile Go binary for Windows
echo "[1/3] Cross-compiling Go binary for Windows..."
cd "${SCRIPT_DIR}"

export GOOS=windows
export GOARCH=amd64
export CGO_ENABLED=1
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++

go mod tidy 2>/dev/null || true

go build -trimpath -buildmode=pie \
    -ldflags="-s -w" \
    -o "${TEMP_BIN}" \
    .

BASE_SIZE=$(stat -c%s "${TEMP_BIN}")
echo "  Base binary: $(to_mb ${BASE_SIZE}) MB"

# Step 2: Append model data to binary
echo ""
echo "[2/3] Appending model data to binary..."
cat "${TEMP_BIN}" "${MODEL_FILE}" > "${OUTPUT}"
chmod +x "${OUTPUT}"

TOTAL_SIZE=$(stat -c%s "${OUTPUT}")
echo "  Total binary: $(to_mb ${TOTAL_SIZE}) MB"

# Step 3: Generate checksum and metadata
echo ""
echo "[3/3] Generating checksums..."
FINAL_HASH=$(sha256sum "${OUTPUT}" | cut -d' ' -f1)

cat > "${OUTPUT}.meta.json" << EOF
{
    "name": "ollama-local",
    "model": "gemma-2-2b-it-Q4_K_M",
    "model_sha256": "${MODEL_HASH}",
    "model_size": ${MODEL_SIZE},
    "binary_sha256": "${FINAL_HASH}",
    "binary_size": ${TOTAL_SIZE},
    "target": "windows/amd64",
    "server": "127.0.0.1:11434",
    "api": "/v1/chat/completions (OpenAI compatible)"
}
EOF

# Cleanup
rm -f "${TEMP_BIN}"

echo ""
echo "============================================"
echo "  Build complete!"
echo "============================================"
echo ""
echo "Output: ${OUTPUT}"
echo "  Size: $(to_mb ${TOTAL_SIZE}) MB"
echo "  SHA256: ${FINAL_HASH}"
echo ""
echo "Metadata: ${OUTPUT}.meta.json"
echo ""
echo "Usage on Windows:"
echo "  1. Copy ollama-local.exe to your machine"
echo "  2. Double-click to run (or from CMD/PowerShell)"
echo "  3. First run extracts model (~30-60 seconds)"
echo "  4. Server starts on http://127.0.0.1:11434"
echo "  5. Interactive chat starts automatically"
echo ""
echo "API Usage:"
echo '  curl http://127.0.0.1:11434/v1/chat/completions \'
echo '    -H "Content-Type: application/json" \'
echo '    -d "{\"model\":\"gemma-2-2b-it\",\"messages\":[{\"role\":\"user\",\"content\":\"Hello!\"}],\"stream\":true}"'
echo ""
