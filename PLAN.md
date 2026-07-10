# Composite Ollama Binary — Plan

## Goal

Produce a **single executable** that bundles an LLM model and runs as a self-contained inference server with:
- Direct inference (CLI chat)
- OpenAI-compatible chat completions API (`/v1/chat/completions`)
- CPU inference by default, with optional Intel GPU acceleration via Vulkan
- Zero external dependencies at runtime (no `ollama` install, no model download)

---

## Architecture Overview

```
┌──────────────────────────────────────────────────┐
│              Single Executable (.elf)             │
│                                                  │
│  ┌─────────────────┐  ┌───────────────────────┐  │
│  │   Go Binary     │  │  Appended GGUF Data   │  │
│  │  (~30 MB)       │  │  (~1-2 GB)            │  │
│  │                 │  │                       │  │
│  │  • Server       │  │  • Model weights      │  │
│  │  • CLI          │  │  • Chat template      │  │
│  │  • Model loader │  │  • Quantization       │  │
│  │  • OpenAI API   │  │                       │  │
│  └─────────────────┘  └───────────────────────┘  │
│                                                  │
│  + bundled llama-server binary (extracted at     │
│    runtime alongside model)                       │
└──────────────────────────────────────────────────┐
                        │
                        ▼  (first-run extraction)
┌──────────────────────────────────────────────────┐
│              Runtime Layout                      │
│                                                  │
│  ~/.cache/ollama-local/                          │
│  ├── blobs/                                      │
│  │   └── sha256-<digest>    ← model weights      │
│  ├── manifests/                                  │
│  │   └── registry.localhost/...                  │
│  │       └── <name>:latest                       │
│  └── lib/ollama/                                 │
│      └── llama-server        ← inference engine  │
│                                                  │
│  OLLAMA_MODELS=~/.cache/ollama-local             │
│  Server listens on 127.0.0.1:11434               │
└──────────────────────────────────────────────────┘
```

---

## Design Decisions

### Why NOT `//go:embed` for the model?

Go's `//go:embed` embeds file contents as compile-time constants in the binary's `.rodata` section. This is **impractical** for multi-GB model files because:
- Base64 encoding inflates size by ~33% during compilation
- Compiler must hold the entire content in memory
- Some linkers have section size limits (Windows PE: 2 GB)
- Cannot stream the data — it's all loaded at once

### Why binary concatenation?

ELF binaries (Linux) ignore data appended after the last `PT_LOAD` segment. This is a well-known technique used by Node.js, Go, and many other runtimes to bundle data:

```bash
go build -o ollama-local ./cmd/ollama-local
cat model.gguf >> ollama-local
chmod +x ollama-local
```

At runtime, the Go binary:
1. Resolves its own path via `os.Executable()`
2. Parses the ELF header with `debug/elf` to find the end of the last `PT_LOAD` segment
3. Everything after that offset is the appended payload (model data)
4. Streams the payload to a cache file on disk (never loads fully into memory)

### Why fork Ollama vs. wrap llama.cpp directly?

| Aspect | Fork Ollama | Raw llama.cpp wrapper |
|--------|-------------|----------------------|
| OpenAI API | Built-in, tested | Must implement |
| Model management | Manifest system, layers | Manual |
| CLI (run/pull/chat) | Ready | Must implement |
| GPU discovery | Vulkan, CUDA, ROCm | Manual config |
| Modifications needed | Minimal (model loader) | Everything |
| Binary complexity | Higher (Go + C++) | Lower (C++ only) |

**Decision: Fork Ollama** with minimal modifications to the model resolution layer. This gives us the full API, CLI, and GPU support for free.

### Model selection criteria

For CPU inference on a corporate laptop:
- **Small parameter count** (1-3B) for fast inference
- **Pure llama.cpp architecture** (no Ollama engine dependency)
- **Q4_K_M quantization** — best balance of quality and speed
- **Strong benchmark scores** for reasoning and coding

| Candidate | Params | Q4_K_M Size | Architecture | Notes |
|-----------|--------|-------------|--------------|-------|
| **Gemma 2 2B** | 2.6B | ~1.7 GB | `gemma2` | Excellent quality, pure llama.cpp |
| Llama 3.2 1B | 1.2B | ~0.9 GB | `llama` | Smallest, fast, but less capable |
| Llama 3.2 3B | 3.2B | ~2.1 GB | `llama` | Good quality, larger binary |
| Phi-3 Mini 3.8B | 3.8B | ~2.5 GB | `phi3` | Good for coding, slower on CPU |

**Recommendation: Gemma 2 2B Q4_K_M** (~1.7 GB). Best quality-to-size ratio, runs well on CPU, pure llama.cpp compatible.

### GPU strategy

Intel GPUs on Linux are supported exclusively through **Vulkan** in the Ollama/llama.cpp ecosystem. No SYCL/oneAPI integration exists.

- Vulkan is enabled by default in Ollama's build
- Intel GPU detection is built-in via `Intel(R) Graphics` pattern matching
- Controlled via `OLLAMA_VULKAN` (enable/disable) and `GGML_VK_VISIBLE_DEVICES`
- Fallback to CPU is automatic if no GPU is detected

**Decision: Build with Vulkan support.** No extra flags needed — it's the default. The binary will auto-detect Intel GPUs and fall back to CPU transparently.

---

## Implementation Plan

### Phase 1: Custom Model Resolver (Go)

**Goal:** Make Ollama load models from an embedded source instead of (or in addition to) the filesystem.

**Files to create/modify:**

1. **`embedded/embedded.go`** — New package
   - `DetectAppendedData() (path string, offset int64, size int64, err error)`
     - Opens `os.Executable()`, parses ELF header, finds trailing data
     - Returns the offset and size of appended payload
   - `ExtractToCache(cacheDir string) (string, error)`
     - Streams appended data to `<cacheDir>/blobs/<sha256>`
     - Uses `io.Copy()` with a buffered reader (never loads fully into memory)
     - Verifies SHA256 checksum after extraction
     - Returns the blob path for use by Ollama's loader
   - `NeedsExtraction() bool` — Check if model already extracted

2. **`embedded/toc.go`** — Table of contents for multi-model support
   - Binary format appended before GGUF data:
     ```
     [4 bytes] Magic: "OLLM"
     [1 byte]  Version: 0x01
     [1 byte]  Reserved
     [2 bytes] Entry count (big-endian uint16)
     [N entries]
       [8 bytes] Offset from TOC end (big-endian uint64)
       [8 bytes] Size (big-endian uint64)
       [32 bytes] SHA256 checksum
       [variable] Null-terminated name string
     [GGUF data...]
     ```
   - Allows bundling multiple models with selective extraction

3. **`server/embedded_loader.go`** — Modify model resolution
   - Hook into the model loading path (`server/images.go`)
   - Before checking `$OLLAMA_MODELS/blobs/`, check if the executable has appended data
   - If model not found on disk, trigger extraction from embedded data
   - Register an in-memory manifest for the embedded model so `ollama list` and API work

4. **`cmd/serve-embedded.go`** — New CLI command (or modify existing `serve`)
   - On `ollama-local serve`:
     1. Check for appended model data
     2. Extract to cache if needed
     3. Set `OLLAMA_MODELS` to cache directory
     4. Register embedded model manifest
     5. Start server as normal

**Key modification points in existing code:**
- `server/images.go` — `parseFromModel()`, model path resolution
- `server/routes.go` — Server startup, add embedded model registration
- `manifest/paths.go` — Blob path resolution
- `llm/llama_server.go` — Model path passed to llama-server subprocess

### Phase 2: Build System (CMake + Go)

**Goal:** Produce a single executable with model + llama-server bundled.

1. **`scripts/build-composite.sh`** — New build script
   ```bash
   #!/bin/bash
   set -euo pipefail

   MODEL_FILE="${1:?Usage: build-composite.sh <model.gguf> [output]}"
   OUTPUT="${2:-ollama-local}"

   # Step 1: Build llama-server (CPU + Vulkan)
   cmake -B build \
     -DCMAKE_BUILD_TYPE=Release \
     -DGGML_CPU=ON \
     -DGGML_VULKAN=ON \
     .
   cmake --build build --target llama-server --parallel

   # Step 2: Build Go binary
   go build -trimpath -buildmode=pie \
     -ldflags="-s -w -X github.com/ollama/ollama/version=local-$(date +%Y%m%d)" \
     -o "${OUTPUT}.bin" .

   # Step 3: Create model TOC and append
   # (build TOC header + GGUF data)
   python3 scripts/create-toc.py "${MODEL_FILE}" > "${OUTPUT}.toc"

   # Step 4: Concatenate
   cat "${OUTPUT}.bin" "${OUTPUT}.toc" > "${OUTPUT}"
   chmod +x "${OUTPUT}"

   # Step 5: Bundle llama-server inside Go binary resources
   # (embed llama-server path for extraction at runtime)
   # Option A: embed llama-server binary via //go:embed (it's only ~10-20MB)
   # Option B: append after model data (part of TOC)

   rm -f "${OUTPUT}.bin" "${OUTPUT}.toc"

   echo "Built ${OUTPUT} ($(du -h "${OUTPUT}" | cut -f1))"
   ```

2. **`scripts/create-toc.py`** — TOC header generator
   - Reads GGUF file, computes SHA256
   - Writes TOC header with model metadata
   - Outputs TOC + model data to stdout

3. **Embed llama-server in Go binary**
   - llama-server is ~10-20 MB (much smaller than the model)
   - Use `//go:embed` for the llama-server binary — this is practical at this size
   - On first run, extract to `~/.cache/ollama-local/lib/ollama/llama-server`
   - Alternatively, append after model data in the TOC

### Phase 3: Runtime Behavior

**First run flow:**
```
User runs: ./ollama-local serve

1. Detect appended data in executable
2. Create ~/.cache/ollama-local/
3. Extract llama-server (from //go:embed) → lib/ollama/llama-server
4. Extract model (from appended data) → blobs/sha256-<digest>
   - Stream with progress: "Extracting model... [██████░░░░] 60%"
5. Register model manifest in manifests/
6. Set OLLAMA_MODELS=~/.cache/ollama-local
7. Start Ollama server on :11434
8. Model auto-loads on first request (or pre-load via /api/load)
```

**Subsequent runs:**
```
1. Detect appended data
2. Check if blob already exists at expected path
3. If checksum matches → skip extraction
4. If checksum differs → re-extract (model was updated)
5. Start server
```

**CLI mode (direct inference):**
```
User runs: ./ollama-local chat

1. Same extraction flow as serve
2. Start server in background
3. Connect CLI client to local server
4. Interactive chat session
5. Kill server on exit
```

### Phase 4: API Surface

No modifications needed — Ollama's built-in API covers everything:

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/v1/chat/completions` | POST | OpenAI-compatible chat (streaming) |
| `/v1/completions` | POST | Legacy completions |
| `/v1/models` | GET | List available models |
| `/api/chat` | POST | Ollama-native chat |
| `/api/generate` | POST | Ollama-native generation |
| `/api/tags` | GET | List local models |

The embedded model will appear in `ollama list` and `/v1/models` just like a pulled model.

### Phase 5: Packaging & Distribution

**Build artifacts:**
```
ollama-local-linux-amd64    # Main binary with model (~2-3 GB)
ollama-local-linux-arm64    # ARM variant (Apple Silicon, etc.)
ollama-local.sha256         # Checksums
```

**Distribution considerations:**
- Binary size exceeds GitHub's 2 GB release asset limit for larger models
- Use direct download links, GCS/S3, or split archives for distribution
- Consider offering multiple model variants (1B, 2B, 3B) as separate binaries
- Code signing is invalidated by appending data — sign after concatenation

---

## File Structure

```
ollama-local/                    # Fork of Ollama
├── embedded/                    # NEW: Embedded model handling
│   ├── embedded.go              # ELF parsing, extraction logic
│   ├── toc.go                   # Table of contents format
│   └── llama_server.go          # llama-server extraction
├── server/
│   ├── images.go                # MODIFIED: Add embedded model resolution
│   ├── routes.go                # MODIFIED: Register embedded models on startup
│   └── embedded_loader.go       # NEW: Bridge between embedded and Ollama's loader
├── cmd/
│   └── serve.go                 # MODIFIED: Handle embedded model flow
├── manifest/
│   └── paths.go                 # MODIFIED: Support embedded blob paths
├── scripts/
│   ├── build-composite.sh       # NEW: Composite binary build script
│   └── create-toc.py            # NEW: TOC header generator
├── main.go                      # MODIFIED: Init embedded model system
├── Makefile                     # NEW or MODIFIED: Composite build targets
└── ...                          # Rest of Ollama codebase (unchanged)
```

---

## Risk Analysis

| Risk | Impact | Mitigation |
|------|--------|------------|
| Binary too large for GitHub releases | High | Use alternative distribution (S3, direct links); offer smaller model variants |
| First-run extraction takes time | Medium | Show progress bar; allow pre-extraction via `--extract` flag |
| Code signing invalidated by append | Medium | Sign after concatenation; document for enterprise users |
| Model format changes break TOC | Low | Version field in TOC; checksum verification |
| llama-server extraction fails | High | Verify binary hash after extraction; retry with fresh download as fallback |
| Corporate laptop without Vulkan drivers | Low | Falls back to CPU automatically; no GPU support is acceptable for 1-3B models |

---

## Alternative Approaches (Considered & Rejected)

### A. Pure llama.cpp wrapper
Build a minimal Go binary that only wraps llama-server. Simpler codebase but lose:
- OpenAI API compatibility layer
- Model manifest management
- CLI commands (run, chat, etc.)
- GPU auto-discovery
- Future Ollama updates

### B. Docker container
Package everything in a Docker image. Simpler distribution but:
- Requires Docker runtime
- No "single executable" experience
- Slower startup

### C. Sidecar model directory
Ship binary + model directory separately. Not a single executable, but simpler to build. User must keep them together.

### D. Download model on first run
Binary downloads model from internet on first use. Not self-contained; requires network access.

---

## Success Criteria

- [ ] Single executable runs without any prior setup
- [ ] Model is extracted to cache on first run (< 30 seconds for 2B model)
- [ ] Server starts and responds to `/v1/chat/completions` requests
- [ ] CLI chat mode works (`./ollama-local chat`)
- [ ] Intel GPU is auto-detected and used when available
- [ ] CPU fallback works when no GPU is present
- [ ] Subsequent runs skip extraction (instant startup)
- [ ] Binary size documented and under 3 GB (with Gemma 2 2B)

---

## Next Steps

1. **Create the `embedded/` package** with ELF parsing and extraction logic
2. **Modify Ollama's model loader** to support embedded sources
3. **Build the TOC format** and concatenation tooling
4. **Create the composite build script**
5. **Test with a small model** (Llama 3.2 1B, ~0.9 GB) first
6. **Validate API compatibility** with OpenAI SDK clients
7. **Benchmark CPU inference** on target hardware
8. **Package and distribute** final binary
