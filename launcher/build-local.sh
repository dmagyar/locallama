#!/bin/bash
set -euo pipefail

# Build ollama-local for a target platform
# Usage: ./build-local.sh [windows|linux] [model.gguf] [output-suffix] [model-name] [model-display-name] [model-download-url]
#
# Examples:
#   # Embedded model (traditional, large binary):
#   ./build-local.sh linux                                    # default gemma-2-2b-it
#   ./build-local.sh windows ../build/gemma-4-E2B-it-qat-Q4_0.gguf -g4 "gemma-4-E2B-it" "Gemma 4 E2B IT QAT_Q4_0"
#
#   # Slim binary (downloads model on first run):
#   ./build-local.sh windows "" -g4 "gemma-4-E2B-it" "Gemma 4 E2B IT QAT_Q4_0" "https://example.com/model.gguf"
#
# Note: model-display-name uses underscores for ldflags safety.
#       They are replaced with spaces at runtime.
#
# Architecture:
#   - Server binary (llama-server) embedded via //go:embed (~63 MB)
#   - Model: either embedded (appended) OR downloaded on first run
#   - Sidecar: place a .gguf file next to the exe to use without download

TARGET="${1:-linux}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODEL_FILE="${2:-}"
OUTPUT_SUFFIX="${3:-}"
MODEL_NAME="${4:-gemma-2-2b-it}"
MODEL_DISPLAY="${5:-Gemma 2 2B IT (Q4_K_M)}"
MODEL_URL="${6:-}"

# If model file not specified but no URL either, use default
if [ -z "${MODEL_FILE}" ] && [ -z "${MODEL_URL}" ]; then
    MODEL_FILE="${SCRIPT_DIR}/../build/gemma-2-2b-it-Q4_K_M.gguf"
fi

# Determine mode
EMBED_MODEL=false
if [ -n "${MODEL_FILE}" ] && [ -f "${MODEL_FILE}" ]; then
    EMBED_MODEL=true
fi

SLIM=false
if [ "${EMBED_MODEL}" = false ] && [ -n "${MODEL_URL}" ]; then
    SLIM=true
fi

MODE="embedded"
if [ "${SLIM}" = true ]; then
    MODE="slim (download on first run)"
fi

to_mb() { python3 -c "print(f'{$1/1048576:.1f}')" 2>/dev/null || echo "$(($1 / 1048576))"; }

echo "=== Building ollama-local${OUTPUT_SUFFIX} for ${TARGET} [${MODE}] ==="
echo "  Model: ${MODEL_DISPLAY}"

# Verify server binary exists
case "${TARGET}" in
windows)
    SERVER_FILE="${SCRIPT_DIR}/servers/windows/llama-server.exe"
    ;;
linux)
    SERVER_FILE="${SCRIPT_DIR}/servers/linux/llama-server"
    ;;
*)
    echo "Usage: $0 [windows|linux] [model.gguf] [suffix] [model-name] [display-name] [download-url]"
    exit 1
    ;;
esac

if [ ! -f "${SERVER_FILE}" ]; then
    echo "ERROR: Server binary not found: ${SERVER_FILE}"
    echo "Build patched llama-server first (see llama-src/ for source)"
    exit 1
fi

if [ "${EMBED_MODEL}" = true ] && [ ! -f "${MODEL_FILE}" ]; then
    echo "ERROR: Model file not found: ${MODEL_FILE}"
    exit 1
fi

SERVER_SIZE=$(stat -c%s "${SERVER_FILE}")
echo "  Server: $(to_mb ${SERVER_SIZE}) MB"
if [ "${EMBED_MODEL}" = true ]; then
    MODEL_SIZE=$(stat -c%s "${MODEL_FILE}")
    echo "  Model:  $(to_mb ${MODEL_SIZE}) MB (embedded)"
elif [ -n "${MODEL_URL}" ]; then
    echo "  URL:    ${MODEL_URL}"
fi

# Set build env
case "${TARGET}" in
windows)
    export GOOS=windows
    export GOARCH=amd64
    export CGO_ENABLED=1
    export CC=x86_64-w64-mingw32-gcc
    export CXX=x86_64-w64-mingw32-g++
    EXE_SUFFIX=".exe"
    ;;
linux)
    export GOOS=linux
    export GOARCH=amd64
    export CGO_ENABLED=1
    EXE_SUFFIX=""
    ;;
esac

cd "${SCRIPT_DIR}"
go mod tidy 2>/dev/null || true

BASE_BIN="${SCRIPT_DIR}/../build/ollama-local-base${OUTPUT_SUFFIX}${EXE_SUFFIX}"
OUTPUT="${SCRIPT_DIR}/../build/ollama-local${OUTPUT_SUFFIX}-${TARGET}${EXE_SUFFIX}"

# Build with ldflags to inject model name, display name, and download URL
SAFE_DISPLAY="${MODEL_DISPLAY// /_}"
SAFE_DISPLAY="${SAFE_DISPLAY//[(]/}"
SAFE_DISPLAY="${SAFE_DISPLAY//[)]/}"
LDFLAGS="-s -w \
  -X main.modelName=${MODEL_NAME} \
  -X main.modelDisplayName=${SAFE_DISPLAY} \
  -X main.modelDownloadURL=${MODEL_URL}"

echo "[1/$(if ${EMBED_MODEL}; then echo 2; else echo 1; fi)] Compiling base binary..."
go build -trimpath -buildmode=pie -ldflags="${LDFLAGS}" -o "${BASE_BIN}" .

BASE_SIZE=$(stat -c%s "${BASE_BIN}")
echo "  Base: $(to_mb ${BASE_SIZE}) MB"

if [ "${EMBED_MODEL}" = true ]; then
    echo "[2/2] Appending model with TOC..."

    # Build TOC + padding + model using Python for precise binary output
    python3 -c "
import struct, hashlib, sys

exe_path = sys.argv[1]
model_path = sys.argv[2]
out_path = sys.argv[3]

PAGE_SIZE = 4096

with open(model_path, 'rb') as f:
    model_data = f.read()
model_size = len(model_data)
model_sha = hashlib.sha256(model_data).digest()

with open(exe_path, 'rb') as f:
    exe_data = f.read()

toc = b'OLLM' + struct.pack('<Q', model_size) + model_sha
header = exe_data + toc
pad_needed = (PAGE_SIZE - (len(header) % PAGE_SIZE)) % PAGE_SIZE
padding = b'\x00' * pad_needed

with open(out_path, 'wb') as f:
    f.write(header)
    f.write(padding)
    f.write(model_data)
" "${BASE_BIN}" "${MODEL_FILE}" "${OUTPUT}"
    chmod +x "${OUTPUT}"
    rm -f "${BASE_BIN}"
else
    # Slim build — no model appended, just the binary
    mv "${BASE_BIN}" "${OUTPUT}"
    chmod +x "${OUTPUT}"
fi

TOTAL_SIZE=$(stat -c%s "${OUTPUT}")
echo ""
echo "=== Build complete ==="
echo "  Output: ${OUTPUT}"
echo "  Size:   $(to_mb ${TOTAL_SIZE}) MB"
echo "  SHA256: $(sha256sum "${OUTPUT}" | cut -d' ' -f1)"
if [ "${SLIM}" = true ]; then
    echo ""
    echo "  This is a slim binary — model downloads on first run."
    echo "  Or place a .gguf file next to the exe for offline use."
fi
echo ""
