# Ollama Local — Self-Contained LLM Server

A single-executable LLM server that bundles `llama-server` and runs with **zero external dependencies**. Drop the binary on any machine, run it, and get an OpenAI-compatible chat completions API on `127.0.0.1:11434`.

## Features

- **Single executable** — Go binary with embedded `llama-server` (no installs, no PATH setup)
- **OpenAI-compatible API** — `/v1/chat/completions` with streaming support
- **Interactive CLI chat** — built-in TUI for direct conversation
- **Auto device detection** — discovers GPU/NPU and configures inference automatically
- **Multi-device support** — layer-split across GPU + NPU when available
- **Flexible model loading** — sidecar `.gguf` file, embedded model, or first-run download
- **Windows & Linux** — cross-platform builds with GPU acceleration

## Architecture

```
llama-local.exe (single binary)
├── Go launcher (~30 MB)
│   ├── Server extraction + startup
│   ├── CLI chat client
│   ├── OpenAI API proxy
│   └── Device auto-detection
├── Embedded llama-server (~60 MB)
│   └── Cross-compiled from llama.cpp
└── Runtime DLLs (Windows, ~800 MB)
    └── oneMKL / oneDNN / TBB / SYCL runtime
```

At startup, the launcher extracts `llama-server` and its dependencies to a temp directory, auto-detects available devices, resolves the model, and starts the inference server.

## Quick Start

### Using the prebuilt binary

1. Download `llama-local.exe` (Windows) or `llama-local` (Linux)
2. Place a `.gguf` model file next to the executable (or let it download on first run)
3. Run:

```bash
# Windows
.\llama-local.exe

# Linux
./llama-local
```

The server starts on `http://127.0.0.1:11434` and opens the UI in your browser.

### API usage

```bash
curl http://127.0.0.1:11434/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-2-2b-it",
    "messages": [{"role": "user", "content": "Hello!"}],
    "stream": true
  }'
```

## Building

### Prerequisites

- **Go 1.24+**
- **Windows cross-compilation** (for Windows targets):
  - Intel oneAPI Base Toolkit (dpcpp/icx compiler)
  - Visual Studio Build Tools 2022
  - CMake + Ninja
  - Intel oneMKL + oneDNN (for SYCL builds)

### Build steps

```bash
# 1. Build llama-server (see launcher/build*.sh scripts)
#    Cross-compile on Linux or build natively on Windows

# 2. Place the server binary in launcher/servers/<platform>/
#    launcher/servers/windows/llama-server.exe  (Windows)
#    launcher/servers/linux/llama-server        (Linux)

# 3. Build the Go launcher
cd launcher
GOOS=windows GOARCH=amd64 CGO_ENABLED=0 go build \
  -ldflags="-s -w \
    -X main.modelName=gemma-2-2b-it \
    -X main.modelDisplayName=Gemma_2_2B_IT_Q4_K_M" \
  -o ../dist/llama-local.exe

# 4. (Optional) Append a model for embedded loading
cat your-model.gguf >> dist/llama-local.exe
```

### Build flags

| Flag | Description | Default |
|------|-------------|---------|
| `main.modelName` | Model name for API | `gemma-2-2b-it` |
| `main.modelDisplayName` | Display name (underscores for spaces) | `Gemma_2_2B_IT_Q4_K_M` |
| `main.modelDownloadURL` | URL to download model on first run | *(empty)* |

## SYCL Build (Intel GPU)

For Intel Arc GPU acceleration on Windows, build llama-server with SYCL:

```bash
# On Windows with oneAPI installed
call vcvars64.bat
set PATH=C:\Intel\compiler\latest\bin;%PATH%
set LIB=C:\Intel\compiler\latest\lib;%LIB%

cmake -B build-sycl -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_SYCL=ON ^
  -DGGML_SYCL_TARGET=INTEL ^
  -DGGML_SYCL_DNN=ON ^
  -DGGML_SYCL_SUPPORT_LEVEL_ZERO_API=ON ^
  -DGGML_CPU=ON ^
  -DGGML_OPENMP=ON ^
  -DBUILD_SHARED_LIBS=OFF ^
  -DLLAMA_SERVER=ON ^
  .

ninja -C build-sycl llama-server
```

Then collect the runtime DLLs and place them alongside `llama-server.exe` in `launcher/servers/windows/`.

See `launcher/build-sycl-full.bat` and `launcher/collect-sycl-dlls.bat` for automated scripts.

### Runtime DLLs required (SYCL)

| Category | Key DLLs |
|----------|----------|
| SYCL runtime | `sycl9.dll`, `sycl-jit.dll`, `common_clang64.dll` |
| oneMKL | `mkl_sycl_blas.6.dll`, `mkl_core.3.dll`, `mkl_rt.3.dll` |
| oneDNN | `dnnl.dll` |
| TBB | `tbb12.dll`, `tbbmalloc.dll` |
| Level Zero / UR | `ur_loader.dll`, `ur_adapter_level_zero.dll` |
| Intel OpenCL | `intelocl64.dll`, `OpenCL.dll` |

## CLI Reference

```
Ollama Local - Self-contained LLM Server

Usage: llama-local [options]

Server options (passed to llama-server):
  -c, --ctx-size N          Context size (default: 65536)
  -t, --threads N           CPU threads (default: all cores)
  -b, --batch N             Batch size
  --ubatch N                Upscale batch size
  -fa, --flash-attn [v]     Flash attention (on/off/auto)
  -n, --n-predict N         Max tokens to predict
  --parallel N              Number of parallel sequences
  --n-gpu-layers N          GPU layers (0 = CPU only)
  --device DEV1,DEV2        Devices (auto-detected)
  --split-mode MODE         layer | row | tensor | none
  --tensor-split N0,N1      Proportion per device
  --temperature N           Sampling temperature
  --top-k N                 Top-k sampling
  --host / --port           Listen address and port
  --timeout N               Server timeout in seconds
  -lv, --log-verbose N      Log verbosity (0-3)

  --mlock                   Lock memory (no swap)
  --no-mmap                 Disable memory mapping
  --cache-type-k TYPE       KV cache type for K (f16/q8_0/q4_0)
  --cache-type-v TYPE       KV cache type for V (f16/q8_0/q4_0)
  --flash-attn-all-layers   Enable flash attention for all layers

Examples:
  llama-local -c 32768              # 32k context
  llama-local -fa on                # Force flash attention
  llama-local --n-gpu-layers 0      # CPU only
  llama-local --device vulkan:0     # Specific device
  llama-local --port 8080           # Custom port
```

## Model Loading

Models are resolved in this order:

1. **Sidecar** — place a `.gguf` file next to the executable
2. **Embedded** — model appended to the binary (TOC-based)
3. **Download** — prompted on first run if `modelDownloadURL` is set

## Project Structure

```
├── README.md                 # This file
├── PLAN.md                   # Detailed architecture plan
├── launcher/                 # Go launcher
│   ├── main.go               # Launcher entry point
│   ├── go.mod / go.sum       # Go module
│   ├── sysproc_*.go          # Platform process handling
│   ├── win_ssh.py            # Windows SSH helper
│   ├── servers/              # Embedded server binaries
│   │   ├── windows/          # Windows llama-server + DLLs
│   │   └── linux/            # Linux llama-server
│   ├── build*.sh             # Build scripts
│   ├── build*.bat            # Windows build scripts
│   ├── assemble*.sh          # Binary assembly scripts
│   └── *.ps1                 # PowerShell setup scripts
├── ollama/                   # Ollama upstream (reference)
├── vulkan-mingw/             # Vulkan SDK for cross-compilation
├── CMakeLists.txt            # llama.cpp cross-compile config
├── ggml/                     # GGML backend (llama.cpp)
├── src/                      # llama.cpp source references
├── common/                   # llama.cpp common utilities
├── examples/                 # llama.cpp examples
├── tools/                    # llama.cpp tools
└── tests/                    # llama.cpp tests
```

## License

This project uses components from:
- [llama.cpp](https://github.com/ggerganov/llama.cpp) (MIT)
- [Ollama](https://ollama.com) (MIT)
- Intel oneAPI runtime libraries (proprietary redistributable)
