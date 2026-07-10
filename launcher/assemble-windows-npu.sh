#!/bin/bash
set -euo pipefail

# Assemble Windows GPU+NPU binaries from pre-built server artifacts.
# Prerequisites: windows-npu/ directory with llama-server.exe + DLLs
#
# Usage: ./assemble-windows-npu.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NPU_DIR="${SCRIPT_DIR}/servers/windows-npu"
BACKUP_DIR="${SCRIPT_DIR}/servers/windows-backup"

if [ ! -f "${NPU_DIR}/llama-server.exe" ]; then
    echo "ERROR: ${NPU_DIR}/llama-server.exe not found"
    echo "Run build-windows-npu.bat on your Windows machine first, then copy servers/windows-npu/ here."
    exit 1
fi

echo "=== Assembling Windows GPU+NPU binaries ==="

# Count DLLs
DLL_COUNT=$(find "${NPU_DIR}" -maxdepth 1 -name "*.dll" | wc -l)
SERVER_SIZE=$(stat -c%s "${NPU_DIR}/llama-server.exe")
echo "  Server: $(( SERVER_SIZE / 1048576 )) MB + ${DLL_COUNT} DLLs"

# Backup original windows server dir
mkdir -p "${BACKUP_DIR}"
cp -r "${SCRIPT_DIR}/servers/windows/"* "${BACKUP_DIR}/" 2>/dev/null || true

# Replace with NPU-enabled server + DLLs
rm -f "${SCRIPT_DIR}/servers/windows/"*
cp "${NPU_DIR}"/* "${SCRIPT_DIR}/servers/windows/"

echo "  Replaced servers/windows/ with GPU+NPU artifacts"

# Build
cd "${SCRIPT_DIR}"

export GOOS=windows
export GOARCH=amd64
export CGO_ENABLED=1
export CC=x86_64-w64-mingw32-gcc
export CXX=x86_64-w64-mingw32-g++

echo ""
echo "[1/2] Building Gemma 2 2B IT (GPU+NPU)..."
bash "${SCRIPT_DIR}/build-local.sh" windows \
    "${SCRIPT_DIR}/../build/gemma-2-2b-it-Q4_K_M.gguf" \
    -npu "gemma-2-2b-it" "Gemma_2_2B_IT_Q4_K_M"

echo ""
echo "[2/2] Building Gemma 4 E2B IT QAT (GPU+NPU)..."
bash "${SCRIPT_DIR}/build-local.sh" windows \
    "${SCRIPT_DIR}/../build/gemma-4-E2B-it-qat-Q4_0.gguf" \
    -g4-npu "gemma-4-E2B-it" "Gemma_4_E2B_IT_QAT_Q4_0"

# Restore original
rm -f "${SCRIPT_DIR}/servers/windows/"*
cp "${BACKUP_DIR}"/* "${SCRIPT_DIR}/servers/windows/" 2>/dev/null || true
rmdir "${BACKUP_DIR}" 2>/dev/null || true

echo ""
echo "=== Build complete ==="
ls -lh "${SCRIPT_DIR}/../build/ollama-local*-npu-windows.exe" 2>/dev/null || true
echo ""
echo "These binaries support auto-detection of GPU + NPU."
echo "Run --help for all options."
