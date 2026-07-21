package main

import (
	"bufio"
	"bytes"
	"embed"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

// ─── Embedded server binary (~16 MB, single file per platform) ───

//go:embed servers/*
var serverEmbedFS embed.FS

const (
	serverAddr = "127.0.0.1:11434"
	tocMagic   = "OLLM"
	pageSize   = 4096
)

// Model name — set at build time via -ldflags "-X main.modelName=..."
var modelName = "gemma-2-2b-it"

// Model display name — set at build time via -ldflags "-X main.modelDisplayName=..."
// Uses underscores for ldflags safety; displayName replaces them at init.
var modelDisplayName = "Gemma_2_2B_IT_Q4_K_M"

// modelDownloadURL — set at build time via -ldflags "-X main.modelDownloadURL=..."
// Default: downloads Gemma-4 E4B on first run when no model is found.
var modelDownloadURL = "https://ur.gd/dm/ur/gemma4-e4b.gguf"

// displayName is the user-facing version with spaces restored
var displayName = strings.ReplaceAll(modelDisplayName, "_", " ")

func serverBinaryName() string {
	if runtime.GOOS == "windows" {
		return "llama-server.exe"
	}
	return "llama-server"
}

// ─── Server binary extraction ───

func extractServerToTemp() (dir, serverPath string, cleanup func(), err error) {
	dir, err = os.MkdirTemp("", "ollama-local")
	if err != nil {
		return "", "", nil, fmt.Errorf("create temp dir: %w", err)
	}
	cleanup = func() { os.RemoveAll(dir) }

	name := serverBinaryName()
	serverPath = filepath.Join(dir, name)

	var embedKey string
	var subdir string
	if runtime.GOOS == "windows" {
		embedKey = "servers/windows/" + name
		subdir = "servers/windows"
	} else {
		embedKey = "servers/linux/" + name
		subdir = "servers/linux"
	}

	data, err := serverEmbedFS.ReadFile(embedKey)
	if err != nil {
		cleanup()
		return "", "", nil, fmt.Errorf("read embedded server: %w", err)
	}
	if err := os.WriteFile(serverPath, data, 0755); err != nil {
		cleanup()
		return "", "", nil, fmt.Errorf("write server: %w", err)
	}
	log.Printf("Server binary extracted: %.1f MB", float64(len(data))/1024/1024)

	// On Windows, also extract any DLLs alongside the server
	if runtime.GOOS == "windows" {
		entries, err := serverEmbedFS.ReadDir(subdir)
		if err == nil {
			for _, e := range entries {
				fn := e.Name()
				if strings.HasSuffix(strings.ToLower(fn), ".dll") {
					// embed.FS always uses forward slashes, regardless of OS
					dllKey := subdir + "/" + fn
					dllData, err := serverEmbedFS.ReadFile(dllKey)
					if err != nil {
						continue
					}
					dllPath := filepath.Join(dir, fn)
					if err := os.WriteFile(dllPath, dllData, 0755); err != nil {
						return "", "", cleanup, fmt.Errorf("write DLL %s: %w", fn, err)
					}
				}
			}
		}
	}

	return dir, serverPath, cleanup, nil
}

// ─── TOC-based model discovery in this executable ───

// tocResult holds the location of the embedded model within the executable.
type tocResult struct {
	modelOffset int64 // byte offset of model data (after 44-byte TOC)
	modelSize   int64 // size of model data in bytes
}

func findModelInExe() (*tocResult, error) {
	exePath, err := os.Executable()
	if err != nil {
		return nil, fmt.Errorf("find executable: %w", err)
	}

	f, err := os.Open(exePath)
	if err != nil {
		return nil, fmt.Errorf("open executable: %w", err)
	}
	defer f.Close()

	stat, err := f.Stat()
	if err != nil {
		return nil, err
	}
	fileSize := stat.Size()

	// Estimate the binary boundary (end of last section) and scan forward
	// for the TOC marker. This works for both ELF and PE formats.
	f.Seek(0, 0)
	header := make([]byte, 128)
	f.Read(header)

	var scanStart int64
	if header[0] == 0x7f && header[1] == 'E' && header[2] == 'L' && header[3] == 'F' {
		scanStart = estimateELFBoundary(f, fileSize)
	} else if header[0] == 'M' && header[1] == 'Z' {
		scanStart = estimatePEBoundary(f, fileSize)
	} else {
		scanStart = 10 * 1024 * 1024 // fallback
	}

	if scanStart > 0 && scanStart < fileSize-44 {
		return findTOCForward(f, fileSize, scanStart)
	}

	return nil, fmt.Errorf("TOC not found in executable (size: %d, scanStart: %d)", fileSize, scanStart)
}

// findTOCForward scans forward from the binary boundary for the TOC marker.
func findTOCForward(f *os.File, fileSize, scanStart int64) (*tocResult, error) {
	scanRange := int64(10 * 1024 * 1024)
	end := scanStart + scanRange
	if end > fileSize {
		end = fileSize
	}

	buf := make([]byte, 128*1024)
	for offset := scanStart; offset+44 < end; offset += int64(len(buf))-44 {
		chunkEnd := offset + int64(len(buf))
		if chunkEnd > end {
			chunkEnd = end
		}
		f.Seek(offset, 0)
		n, _ := f.Read(buf[:chunkEnd-offset])
		actual := int64(n)

		for i := int64(0); i+44 < actual; i++ {
			if buf[i] == 'O' && buf[i+1] == 'L' && buf[i+2] == 'L' && buf[i+3] == 'M' {
				modelSize := int64(binary.LittleEndian.Uint64(buf[i+4 : i+12]))
				modelOffset := (offset+i+44 + pageSize-1) & ^(pageSize-1)
				if modelSize > 0 && modelOffset+modelSize <= fileSize {
					return &tocResult{
						modelOffset: modelOffset,
						modelSize:   modelSize,
					}, nil
				}
			}
		}
	}
	return nil, fmt.Errorf("TOC not found scanning forward")
}

func estimateELFBoundary(f *os.File, fileSize int64) int64 {
	f.Seek(0, 0)
	header := make([]byte, 64)
	f.Read(header)

	phOffset := uint64(header[32]) | uint64(header[33])<<8 | uint64(header[34])<<16 |
		uint64(header[35])<<24 | uint64(header[36])<<32 | uint64(header[37])<<40 |
		uint64(header[38])<<48 | uint64(header[39])<<56
	phEntrySize := uint16(header[54]) | uint16(header[55])<<8
	phEntries := uint16(header[56]) | uint16(header[57])<<8

	fileSizeU := uint64(fileSize)
	var lastEnd uint64 = 0
	for i := uint16(0); i < phEntries; i++ {
		off := phOffset + uint64(i)*uint64(phEntrySize)
		if off >= fileSizeU {
			break
		}
		f.Seek(int64(off), 0)
		ph := make([]byte, int(phEntrySize))
		f.Read(ph)

		phType := uint32(ph[0]) | uint32(ph[1])<<8 | uint32(ph[2])<<16 | uint32(ph[3])<<24
		if phType != 1 { // PT_LOAD
			continue
		}
		fileOff := uint64(ph[8]) | uint64(ph[9])<<8 | uint64(ph[10])<<16 |
			uint64(ph[11])<<24 | uint64(ph[12])<<32 | uint64(ph[13])<<40 |
			uint64(ph[14])<<48 | uint64(ph[15])<<56
		fileSz := uint64(ph[32]) | uint64(ph[33])<<8 | uint64(ph[34])<<16 |
			uint64(ph[35])<<24 | uint64(ph[36])<<32 | uint64(ph[37])<<40 |
			uint64(ph[38])<<48 | uint64(ph[39])<<56
		if fileOff > fileSizeU || fileSz > fileSizeU {
			continue
		}
		end := fileOff + fileSz
		if end > lastEnd && end <= fileSizeU {
			lastEnd = end
		}
	}
	return int64(lastEnd)
}

func estimatePEBoundary(f *os.File, fileSize int64) int64 {
	f.Seek(0, 0)
	header := make([]byte, 128)
	f.Read(header)

	// DOS header: e_lfanew at offset 0x3C (4 bytes LE) = offset to PE signature
	peSigOffset := uint32(header[0x3C]) | uint32(header[0x3D])<<8 |
		uint32(header[0x3E])<<16 | uint32(header[0x3F])<<24

	f.Seek(int64(peSigOffset), 0)
	peSig := make([]byte, 128)
	f.Read(peSig)

	// COFF header starts after "PE\0\0" signature (4 bytes)
	// NumberOfSections at COFF[2:4], SizeOfOptionalHeader at COFF[16:18]
	optSize := uint32(peSig[20]) | uint32(peSig[21])<<8
	numSections := uint16(peSig[6]) | uint16(peSig[7])<<8

	// Section table: PE sig (4) + COFF header (20) + optional header
	sectionTableOff := peSigOffset + 4 + 20 + optSize
	sectionHeaderSize := uint32(40) // IMAGE_SIZEOF_SECTION_HEADER

	fileSizeU := uint64(fileSize)
	var lastEnd uint64 = 0

	for i := uint16(0); i < numSections; i++ {
		off := sectionTableOff + uint32(i)*sectionHeaderSize
		if uint64(off) >= fileSizeU {
			break
		}
		f.Seek(int64(off), 0)
		sh := make([]byte, int(sectionHeaderSize))
		f.Read(sh)

		// PointerToRawData at offset 16 (4 bytes LE)
		rawData := uint32(sh[16]) | uint32(sh[17])<<8 | uint32(sh[18])<<16 | uint32(sh[19])<<24
		// SizeOfRawData at offset 20 (4 bytes LE)
		rawSize := uint32(sh[20]) | uint32(sh[21])<<8 | uint32(sh[22])<<16 | uint32(sh[23])<<24

		if rawData > 0 && rawSize > 0 {
			end := uint64(rawData) + uint64(rawSize)
			if end > lastEnd && end <= fileSizeU {
				lastEnd = end
			}
		}
	}
	return int64(lastEnd)
}

// ─── Model resolution: sidecar → embedded → download ───

// modelSource describes where the model was found and how to load it
type modelSource struct {
	path    string    // file path (for sidecar/downloaded) or "" for embedded
	toc     *tocResult // only for embedded models
	method  string    // "sidecar", "embedded", "downloaded"
	sizeMB  float64
}

// extractEmbeddedModel copies the embedded model data from the executable to a temp file.
// Uses io.Copy for efficient streaming (no full model loaded into RAM).
func extractEmbeddedModel(exePath string, toc *tocResult) (string, error) {
	exe, err := os.Open(exePath)
	if err != nil {
		return "", fmt.Errorf("open executable: %w", err)
	}
	defer exe.Close()

	// Create temp file in system temp dir (avoid /dev/shm — often too small for large models)
	tmpFile, err := os.CreateTemp("", "ollama-model-*.gguf")
	if err != nil {
		return "", fmt.Errorf("create temp model: %w", err)
	}
	tmpPath := tmpFile.Name()

	// Seek to model data in executable and stream to temp file
	exe.Seek(toc.modelOffset, 0)
	written, err := io.Copy(tmpFile, io.LimitReader(exe, toc.modelSize))
	tmpFile.Close()
	if err != nil {
		os.Remove(tmpPath)
		return "", fmt.Errorf("copy model data: %w", err)
	}
	if written != toc.modelSize {
		os.Remove(tmpPath)
		return "", fmt.Errorf("incomplete extraction: wrote %d of %d bytes", written, toc.modelSize)
	}

	// Clean up temp model file when process exits
	go func() {
		sigCh := make(chan os.Signal, 1)
		signal.Notify(sigCh, os.Interrupt, syscall.SIGTERM)
		<-sigCh
		os.Remove(tmpPath)
	}()

	return tmpPath, nil
}

// resolveModel finds the model via: sidecar .gguf → embedded → prompt + download
func resolveModel(exePath string) (*modelSource, error) {
	exeDir := filepath.Dir(exePath)

	// 1. Check for sidecar .gguf files in the same directory
	ggufs, _ := filepath.Glob(filepath.Join(exeDir, "*.gguf"))
	if len(ggufs) == 1 {
		fi, err := os.Stat(ggufs[0])
		if err == nil && fi.Size() > 1024*1024 {
			log.Printf("Found sidecar model: %s (%.1f MB)", ggufs[0], float64(fi.Size())/1024/1024)
			return &modelSource{path: ggufs[0], method: "sidecar", sizeMB: float64(fi.Size()) / 1024 / 1024}, nil
		}
	} else if len(ggufs) > 1 {
		log.Printf("Multiple .gguf files found, using embedded model instead")
	}

	// 2. Try embedded model (TOC in executable)
	toc, err := findModelInExe()
	if err == nil {
		log.Printf("Found embedded model: %.1f MB at offset %d", float64(toc.modelSize)/1024/1024, toc.modelOffset)
		// Extract embedded model to temp file (llama-server needs a real file path)
		tmpModel, extractErr := extractEmbeddedModel(exePath, toc)
		if extractErr != nil {
			return nil, fmt.Errorf("extract embedded model: %w", extractErr)
		}
		log.Printf("Extracted embedded model to: %s", tmpModel)
		return &modelSource{path: tmpModel, method: "embedded", sizeMB: float64(toc.modelSize) / 1024 / 1024}, nil
	}

	// 3. No model found — prompt to download if URL is configured
	if modelDownloadURL != "" {
		fmt.Println()
		fmt.Printf("  No model found. Download %s from the internet? (y/n): ", displayName)

		// Check if we have a TTY for interactive input
		fi, _ := os.Stdin.Stat()
		isPipe := (fi.Mode() & os.ModeNamedPipe) != 0
		isTTY := !isPipe && runtime.GOOS != "windows"

		if isTTY || runtime.GOOS == "windows" {
			// Interactive — ask user
			reader := bufio.NewReader(os.Stdin)
			answer, _ := reader.ReadString('\n')
			answer = strings.TrimSpace(strings.ToLower(answer))
			if answer != "y" && answer != "yes" {
				return nil, fmt.Errorf("download declined — place a .gguf file next to this executable and try again")
			}
		}
		// Non-TTY (pipe): auto-download

		return downloadModel(exeDir, exePath)
	}

	return nil, fmt.Errorf("no model found — place a .gguf file next to this executable or set a download URL")
}

// downloadModel fetches the model from modelDownloadURL into the exe directory
func downloadModel(exeDir, exePath string) (*modelSource, error) {
	// Derive filename from URL path
	parsedURL, err := parseURLPath(modelDownloadURL)
	var filename string
	if err != nil {
		filename = modelName + ".gguf"
	} else {
		filename = parsedURL
	}
	dest := filepath.Join(exeDir, filename)

	// Check if already cached
	if fi, err := os.Stat(dest); err == nil && fi.Size() > 1024*1024 {
		log.Printf("Using cached model: %s (%.1f MB)", dest, float64(fi.Size())/1024/1024)
		return &modelSource{path: dest, method: "cached", sizeMB: float64(fi.Size()) / 1024 / 1024}, nil
	}

	fmt.Printf("  Downloading %s...\n", filename)
	fmt.Print("  ")

	// Create a temp file first, then rename (atomic on same filesystem)
	tmpFile := dest + ".download"
	f, err := os.Create(tmpFile)
	if err != nil {
		return nil, fmt.Errorf("create download file: %w", err)
	}

	client := &http.Client{Timeout: 0} // no timeout for large downloads
	resp, err := client.Get(modelDownloadURL)
	if err != nil {
		f.Close()
		os.Remove(tmpFile)
		return nil, fmt.Errorf("download: %w", err)
	}

	if resp.StatusCode != 200 {
		f.Close()
		resp.Body.Close()
		os.Remove(tmpFile)
		return nil, fmt.Errorf("download HTTP %d", resp.StatusCode)
	}

	// Single-line progress bar: [████░░░░░░] 45%  (1.2 / 3.2 GB)
	total := resp.ContentLength
	written := int64(0)
	lastPct := -1
	barLen := 20 // characters for the bar
	buf := make([]byte, 64*1024)

	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			f.Write(buf[:n])
			written += int64(n)
			if total > 0 {
				pct := int(written * 100 / total)
				if pct != lastPct {
					// Build progress bar
					filled := pct * barLen / 100
					bar := "["
					for i := 0; i < barLen; i++ {
						if i < filled {
							bar += "█"
						} else {
							bar += "░"
						}
					}
					bar += "]"

					// Format sizes
					wMB := float64(written) / 1024 / 1024
					tMB := float64(total) / 1024 / 1024
					var sizeStr string
					if tMB > 1024 {
						sizeStr = fmt.Sprintf("%5.1f / %5.1f GB", wMB/1024, tMB/1024)
					} else {
						sizeStr = fmt.Sprintf("%5.0f / %5.0f MB", wMB, tMB)
					}

					fmt.Printf("\r  %s %3d%%  %s", bar, pct, sizeStr)
					lastPct = pct
				}
			}
		}
		if err != nil {
			break
		}
	}
	resp.Body.Close()
	fmt.Println() // newline after progress bar

	f.Close()

	// Verify size
	fi, err := os.Stat(tmpFile)
	if err != nil || fi.Size() < 1024*1024 {
		os.Remove(tmpFile)
		return nil, fmt.Errorf("downloaded file too small (%d bytes)", fi.Size())
	}

	// Atomic rename
	os.Rename(tmpFile, dest)
	log.Printf("Model downloaded: %s (%.1f MB)", dest, float64(fi.Size())/1024/1024)

	return &modelSource{path: dest, method: "downloaded", sizeMB: float64(fi.Size()) / 1024 / 1024}, nil
}

// parseURLPath extracts the filename from a URL (last segment of path)
func parseURLPath(url string) (string, error) {
	// Simple parse without importing net/url — find "//" then take last "/" segment
	afterScheme := strings.Index(url, "//")
	if afterScheme < 0 {
		return "", fmt.Errorf("invalid URL: %s", url)
	}
	path := url[afterScheme+2:]
	// Remove query string
	if i := strings.Index(path, "?"); i >= 0 {
		path = path[:i]
	}
	// Last segment
	lastSlash := strings.LastIndex(path, "/")
	if lastSlash < 0 || lastSlash == len(path)-1 {
		return "", fmt.Errorf("no filename in URL path: %s", url)
	}
	return path[lastSlash+1:], nil
}

// ─── CLI argument parsing & server arg building ───

// serverArgDefault holds a default value for a known llama-server flag
type serverArgDefault struct {
	key   string // canonical key to use in overrides map
	value string // default value (empty = no default, boolean flag)
}

// knownPassthroughFlags maps CLI flags to their defaults.
// Short and long forms both point to the same canonical key.
var knownPassthroughFlags = map[string]*serverArgDefault{
	// context & batching
	"-c":                         {key: "-c", value: "65536"},
	"--ctx-size":                 {key: "-c", value: "65536"},
	"-b":                         {key: "-b", value: ""},
	"--batch":                    {key: "-b", value: ""},
	"--ubatch":                   {key: "--ubatch", value: ""},
	// threading
	"-t":                         {key: "-t", value: ""},
	"--threads":                  {key: "-t", value: ""},
	// attention / memory
	"-fa":                        {key: "-fa", value: ""},
	"--flash-attn":               {key: "-fa", value: ""},
	"--mlock":                    {key: "--mlock", value: ""},
	"--no-mmap":                  {key: "--no-mmap", value: ""},
	"--numa":                     {key: "--numa", value: ""},
	"--cache-type-k":             {key: "--cache-type-k", value: ""},
	"--cache-type-v":             {key: "--cache-type-v", value: ""},
	"--flash-attn-all-layers":    {key: "--flash-attn-all-layers", value: ""},
	// gpu / device
	"--n-gpu-layers":             {key: "--n-gpu-layers", value: ""},
	"--gpu-layers":               {key: "--n-gpu-layers", value: ""},
	"--split-mode":               {key: "--split-mode", value: ""},
	"--tensor-split":             {key: "--tensor-split", value: ""},
	"--main-gpu":                 {key: "--main-gpu", value: ""},
	"--device":                   {key: "--device", value: ""},
	"-dev":                       {key: "--device", value: ""},
	// generation params
	"-n":                         {key: "-n", value: ""},
	"--n-predict":                {key: "-n", value: ""},
	"--parallel":                 {key: "--parallel", value: ""},
	"--n_parallel":               {key: "--n_parallel", value: ""},
	"--temperature":              {key: "--temperature", value: ""},
	"--top-k":                    {key: "--top-k", value: ""},
	// server binding
	"--host":                     {key: "--host", value: ""},
	"--port":                     {key: "--port", value: ""},
	"--timeout":                  {key: "--timeout", value: ""},
	"--no-host":                  {key: "--no-host", value: ""},
	// logging
	"-lv":                        {key: "-lv", value: ""},
	"--log-verbose":              {key: "-lv", value: ""},
}

// parseServerArgs extracts llama-server flags from os.Args.
// Returns a map of canonicalKey -> value (nil = boolean flag, no value).
func parseServerArgs() map[string]*string {
	overrides := make(map[string]*string)
	skipNext := 0

	for i := 1; i < len(os.Args); i++ {
		if skipNext > 0 {
			skipNext--
			continue
		}
		arg := os.Args[i]

		// Direct match?
		def, known := knownPassthroughFlags[arg]
		if !known {
			// Try --flag=value syntax
			for flag, d := range knownPassthroughFlags {
				if strings.HasPrefix(arg, flag+"=") {
					val := strings.TrimPrefix(arg, flag+"=")
					overrides[d.key] = &val
					known = true
					break
				}
			}
		}
		if !known {
			continue // ignore unknown flags
		}

		// Check if next arg is a value (doesn't start with -)
		hasValue := i+1 < len(os.Args) && !strings.HasPrefix(os.Args[i+1], "-")
		if hasValue {
			val := os.Args[i+1]
			overrides[def.key] = &val
			skipNext = 1
		} else {
			// Boolean flag (e.g. --mlock)
			overrides[def.key] = nil
		}
	}
	return overrides
}

// detectDevices runs "llama-server --list-devices" and returns a comma-separated
// device string suitable for --device. It auto-selects GPU + NPU when available.
func detectDevices(serverPath, workDir string) string {
	cmd := exec.Command(serverPath, "--list-devices")
	cmd.Dir = workDir
	if runtime.GOOS == "windows" {
		cmd.Env = append(os.Environ(), fmt.Sprintf("PATH=%s;%s", workDir, os.Getenv("PATH")))
	}
	out, err := cmd.CombinedOutput()
	if err != nil {
		return "" // can't probe, skip auto-detect
	}
	lines := strings.Split(string(out), "\n")
	var gpus, npus []string
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		lower := strings.ToLower(trimmed)
		// Format: "  NAME: DESCRIPTION (SIZE MiB, FREE MiB free)"
		// Extract device name (first token after leading spaces)
		parts := strings.Fields(trimmed)
		if len(parts) < 2 {
			continue
		}
		name := strings.TrimSuffix(parts[0], ":") // remove trailing colon
		if strings.Contains(lower, "npu") {
			npus = append(npus, name)
		} else if strings.Contains(lower, "vulkan") || strings.Contains(lower, "cuda") ||
			strings.Contains(lower, "gpu") || strings.Contains(lower, "opencl") ||
			strings.Contains(lower, "metal") {
			gpus = append(gpus, name)
		}
	}

	var result []string
	result = append(result, gpus...)
	result = append(result, npus...)

	if len(result) == 0 {
		return "" // no GPU/NPU found
	}

	if len(result) == 1 {
		log.Printf("Auto-detected device: %s", result[0])
		return result[0]
	}

	// Multiple devices — combine with split info
	log.Printf("Auto-detected %d devices: %v (using layer split)", len(result), result)
	// Set environment variable to signal split-mode should be added
	os.Setenv("OLLAMA_LOCAL_DEVICES", strings.Join(result, ","))
	os.Setenv("OLLAMA_LOCAL_SPLIT", "layer")
	return strings.Join(result, ",")
}

// openBrowser launches the default browser to the given URL
func openBrowser(url string) {
	var cmd *exec.Cmd
	switch runtime.GOOS {
	case "windows":
		cmd = exec.Command("cmd", "/c", "start", url)
		configureWindowsProcess(cmd)
	case "darwin":
		cmd = exec.Command("open", url)
	default:
		// Linux — try xdg-open, fall back to nothing
		if _, err := exec.LookPath("xdg-open"); err == nil {
			cmd = exec.Command("xdg-open", url)
		}
	}
	if cmd != nil {
		cmd.Stdout = nil
		cmd.Stderr = nil
		if err := cmd.Start(); err == nil {
			log.Printf("Opening UI in browser: %s", url)
		}
	}
}

// buildServerArgs merges hardcoded defaults with user overrides.
func buildServerArgs(overrides map[string]*string, deviceHint string, src *modelSource) []string {
	// Determine model arg: memfile:// for embedded, actual path for sidecar/downloaded
	modelArg := "memfile://"
	if src.path != "" {
		modelArg = src.path
	}

	// Hardcoded defaults — user overrides can replace any of these
	defaults := []struct{ key, value string }{
		{"--model", modelArg},
		{"-a", modelName},
		{"--host", "127.0.0.1"},
		{"--port", "11434"},
		{"--ui", ""},
		{"-c", "65536"}, // 64k context default
		{"-t", fmt.Sprintf("%d", runtime.NumCPU())},
		{"-lv", "1"},
	}

	used := make(map[string]bool)
	var args []string

	for _, d := range defaults {
		if val, ok := overrides[d.key]; ok {
			used[d.key] = true
			if val == nil {
				args = append(args, d.key)
			} else {
				args = append(args, d.key, *val)
			}
		} else if d.value != "" {
			args = append(args, d.key, d.value)
		} else {
			args = append(args, d.key)
		}
	}

	// Auto-inject --device from detection if user didn't specify one
	userDevice := overrides["--device"]
	if userDevice == nil && deviceHint != "" {
		args = append(args, "--device", deviceHint)
		// If multiple devices, auto-add split-mode unless user specified one
		if overrides["--split-mode"] == nil {
			parts := strings.Split(deviceHint, ",")
			if len(parts) > 1 {
				args = append(args, "--split-mode", "layer")
				log.Printf("Auto-enabling layer split across %d devices", len(parts))
			}
		}
	}

	// Append user overrides for flags not in our defaults list
	for key, val := range overrides {
		if !used[key] {
			if val == nil {
				args = append(args, key)
			} else {
				args = append(args, key, *val)
			}
		}
	}

	return args
}

// printServerUsage displays available CLI options
func printServerUsage() {
	fmt.Println()
	fmt.Println("  Ollama Local — Self-contained LLM Server")
	fmt.Println("  Model: " + displayName)
	fmt.Println()
	fmt.Println("  Usage: ollama-local [options]")
	fmt.Println()
	fmt.Println("  Server options (passed to llama-server):")
	fmt.Println()
	fmt.Println("    -c, --ctx-size N          Context size (default: 65536)")
	fmt.Println("    -t, --threads N           CPU threads (default: all cores)")
	fmt.Println("    -b, --batch N             Batch size")
	fmt.Println("    --ubatch N                Upscale batch size")
	fmt.Println("    -fa, --flash-attn [v]     Flash attention (on/off/auto)")
	fmt.Println("    -n, --n-predict N         Max tokens to predict")
	fmt.Println("    --parallel N              Number of parallel sequences")
	fmt.Println("    --n-gpu-layers N          GPU layers (0 = CPU only)")
	fmt.Println("    --device DEV1,DEV2        Devices (auto-detected). e.g. vulkan:0,openvino:NPU")
	fmt.Println("    --split-mode MODE         Split mode: layer (default), row, tensor, none")
	fmt.Println("    --tensor-split N0,N1      Proportion per device (e.g. 3,1)")
	fmt.Println("    --temperature N           Sampling temperature")
	fmt.Println("    --top-k N                 Top-k sampling")
	fmt.Println("    --host N                  Listen address (default: 127.0.0.1)")
	fmt.Println("    --port N                  Listen port (default: 11434)")
	fmt.Println("    --timeout N               Server timeout in seconds")
	fmt.Println("    -lv, --log-verbose N      Log verbosity (0-3)")
	fmt.Println()
	fmt.Println("    --mlock                   Lock memory (no swap)")
	fmt.Println("    --no-mmap                 Disable memory mapping")
	fmt.Println("    --numa                    Enable NUMA support")
	fmt.Println("    --cache-type-k TYPE       KV cache type for K (f16/q8_0/q4_0)")
	fmt.Println("    --cache-type-v TYPE       KV cache type for V (f16/q8_0/q4_0)")
	fmt.Println("    --flash-attn-all-layers   Enable flash attention for all layers")
	fmt.Println()
	fmt.Println("  Examples:")
	fmt.Println("    ollama-local -c 32768              # 32k context")
	fmt.Println("    ollama-local -fa on                 # Force flash attention")
	fmt.Println("    ollama-local --n-gpu-layers 0       # CPU only")
	fmt.Println("    ollama-local --device vulkan:0      # Specific Vulkan device")
	fmt.Println("    ollama-local --port 8080            # Custom port")
	fmt.Println("    ollama-local --mlock --no-mmap      # Memory options")
	fmt.Println()
	fmt.Println("  Multi-device (GPU + NPU auto-detected if available):")
	fmt.Println("    ollama-local                       # Auto: GPU + NPU with layer split")
	fmt.Println("    ollama-local --device vulkan:0,openvino:NPU  # Explicit multi-device")
	fmt.Println("    ollama-local --split-mode tensor    # Tensor parallelism across devices")
	fmt.Println()
	fmt.Println("  Model loading (checked in order):")
	fmt.Println("    1. Sidecar: place a .gguf file next to the executable")
	fmt.Println("    2. Embedded: model built into the binary")
	fmt.Println("    3. Download: prompted on first run (default: Gemma-4 E4B)")
	fmt.Println()
	os.Exit(0)
}

// ─── Start llama-server ───

func startServer(serverPath string, src *modelSource, serverArgs []string) (*exec.Cmd, error) {
	log.Printf("Starting llama-server on %s (%s, %.1f MB)...", serverAddr, src.method, src.sizeMB)
	if len(serverArgs) > 0 {
		log.Printf("Server args: %s", strings.Join(serverArgs, " "))
	}

	cmd := exec.Command(serverPath, serverArgs...)
	cmd.Dir = filepath.Dir(serverPath)

	// On embedded model: pass exe path + offset/size via env vars (memfile:// protocol)
	// On file-path model: the --model arg already has the path, no extra env needed
	if src.toc != nil {
		exePath, _ := os.Executable()
		cmd.Env = append(os.Environ(),
			fmt.Sprintf("OLLAMA_EXE_PATH=%s", exePath),
			fmt.Sprintf("OLLAMA_MODEL_OFFSET=%d", src.toc.modelOffset),
			fmt.Sprintf("OLLAMA_MODEL_SIZE=%d", src.toc.modelSize),
		)
	}

	// On Windows, add server dir to PATH so DLLs are found
	serverDir := filepath.Dir(serverPath)
	if runtime.GOOS == "windows" {
		pathVal := os.Getenv("PATH")
		cmd.Env = append(cmd.Env, fmt.Sprintf("PATH=%s;%s", serverDir, pathVal))
	}

	// Use pipes for stdout/stderr - more reliable on Windows than handle inheritance
	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("create stdout pipe: %w", err)
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("create stderr pipe: %w", err)
	}

	configureWindowsProcess(cmd)

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start server: %w", err)
	}

	log.Printf("Server PID: %d, loading model (%.1f MB)...", cmd.Process.Pid, src.sizeMB)

	// Monitor server process exit
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- cmd.Wait()
	}()

	// Discard server stdout during startup to keep chat clean
	go func() {
		io.Copy(io.Discard, stdoutPipe)
	}()
	// Forward stderr (errors/warnings) without prefix
	go func() {
		scanner := bufio.NewScanner(stderrPipe)
		for scanner.Scan() {
			fmt.Fprintln(os.Stderr, scanner.Text())
		}
	}()

	// Run health check in goroutine so we can race it against server exit
	healthDone := make(chan error, 1)
	go func() {
		healthDone <- waitForHealth(serverAddr, 300)
	}()

	// Wait for either: server healthy, server crashed, or timeout
	select {
	case err := <-serverDone:
		time.Sleep(1 * time.Second) // let remaining output flush
		return nil, fmt.Errorf("server exited prematurely: %w", err)
	case err := <-healthDone:
		if err != nil {
			cmd.Process.Kill()
			<-serverDone // drain the exit channel
			return nil, fmt.Errorf("server health check failed: %w", err)
		}
		log.Printf("Server is ready on http://%s", serverAddr)
		return cmd, nil
	}
}

func waitForHealth(addr string, maxSeconds int) error {
	client := &http.Client{Timeout: 2 * time.Second}
	for i := 0; i < maxSeconds; i++ {
		time.Sleep(time.Second)
		resp, err := client.Get(fmt.Sprintf("http://%s/health", addr))
		if err != nil {
			// Print a waiting indicator every 30s so user knows we're alive
			if i > 0 && i%30 == 0 {
				log.Printf("Waiting for server... (%ds/%ds)", i, maxSeconds)
			}
			continue
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		if resp.StatusCode == 200 {
			var health map[string]interface{}
			if json.Unmarshal(body, &health) == nil {
				if status, ok := health["status"].(string); ok && status == "ok" {
					return nil
				}
			}
			if i > 90 {
				return nil // server responding, good enough
			}
		}
	}
	return fmt.Errorf("server did not become healthy within %ds", maxSeconds)
}

// ─── Chat client ───

type message struct {
	Role    string `json:"role"`
	Content string `json:"content"`
}

type chatRequest struct {
	Model       string    `json:"model"`
	Messages    []message `json:"messages"`
	Stream      bool      `json:"stream"`
	Temperature float64   `json:"temperature,omitempty"`
}

type chatResponse struct {
	Choices []struct {
		Delta struct {
			Content string `json:"content"`
		} `json:"delta"`
		FinishReason string `json:"finish_reason"`
	} `json:"choices"`
}

func chatClient() {
	fmt.Println()
	fmt.Println("  ============================================================")
	fmt.Println("  Ollama Local  |  " + displayName)
	fmt.Println("  API: http://127.0.0.1:11434  |  /v1/chat/completions")
	fmt.Println("  Type /quit to exit  |  /help for commands")
	fmt.Println("  ============================================================")
	fmt.Println()

	reader := bufio.NewReader(os.Stdin)
	conversation := []message{}

	for {
		fmt.Print("\nYou: ")

		input, err := reader.ReadString('\n')
		if err != nil {
			fmt.Println()
			break
		}
		input = strings.TrimSpace(input)
		if input == "" {
			continue
		}

		switch {
		case input == "/quit" || input == "/exit" || input == "/stop":
			fmt.Println("Goodbye!")
			return
		case input == "/help":
			fmt.Println("  /quit  /exit  /stop   - Exit")
			fmt.Println("  /clear                    - Clear conversation")
			fmt.Println("  /stats                    - Server status")
			continue
		case input == "/clear":
			conversation = []message{}
			fmt.Println("Conversation cleared.")
			continue
		case input == "/stats":
			resp, err := http.Get(fmt.Sprintf("http://%s/health", serverAddr))
			if err == nil {
				body, _ := io.ReadAll(resp.Body)
				resp.Body.Close()
				var h map[string]interface{}
				if json.Unmarshal(body, &h) == nil {
					b, _ := json.MarshalIndent(h, "", "  ")
					fmt.Println(string(b))
				} else {
					fmt.Println(string(body))
				}
			}
			continue
		}

		conversation = append(conversation, message{Role: "user", Content: input})
		fmt.Print("Assistant: ")

		assistantReply := streamChat(conversation, func(token string) {
			fmt.Print(token)
		})
		fmt.Println()

		if assistantReply != "" {
			conversation = append(conversation, message{Role: "assistant", Content: assistantReply})
		}
	}
}

func streamChat(messages []message, onToken func(string)) string {
	req := chatRequest{
		Model:       modelName,
		Messages:    messages,
		Stream:      true,
		Temperature: 0.7,
	}

	data, _ := json.Marshal(req)
	resp, err := http.Post(fmt.Sprintf("http://%s/v1/chat/completions", serverAddr),
		"application/json", bytes.NewBuffer(data))
	if err != nil {
		fmt.Printf("(Error: %v)\n", err)
		return ""
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		body, _ := io.ReadAll(resp.Body)
		fmt.Printf("(HTTP %d: %s)\n", resp.StatusCode, string(body))
		return ""
	}

	scanner := bufio.NewScanner(resp.Body)
	scanner.Buffer(make([]byte, 64*1024), 64*1024)

	var fullResponse strings.Builder

	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "data: ") {
			continue
		}
		data := strings.TrimPrefix(line, "data: ")
		if data == "[DONE]" {
			break
		}

		var r chatResponse
		if json.Unmarshal([]byte(data), &r) != nil {
			continue
		}
		for _, c := range r.Choices {
			if c.Delta.Content != "" {
				fullResponse.WriteString(c.Delta.Content)
				onToken(c.Delta.Content)
			}
			if c.FinishReason != "" {
				return fullResponse.String()
			}
		}
	}
	return fullResponse.String()
}

// ─── Warm-up inference ───

func warmupInference() {
	req := chatRequest{
		Model:  modelName,
		Messages: []message{
			{Role: "user", Content: "hi"},
		},
		Stream: false,
	}

	data, _ := json.Marshal(req)
	start := time.Now()
	resp, err := http.Post(fmt.Sprintf("http://%s/v1/chat/completions", serverAddr),
		"application/json", bytes.NewBuffer(data))
	if err != nil {
		log.Printf("Warm-up skipped: %v", err)
		return
	}
	defer resp.Body.Close()

	io.Copy(io.Discard, resp.Body) // discard response body
	elapsed := time.Since(start)
	log.Printf("Warm-up complete in %.1fs — tensors are loaded", elapsed.Seconds())
}

// ─── Main ───

func main() {
	runtime.LockOSThread()

	// Handle --help / -h (before anything else)
	for _, a := range os.Args[1:] {
		if a == "-h" || a == "--help" {
			printServerUsage()
			return
		}
	}

	// Parse llama-server CLI options from arguments
	serverOverrides := parseServerArgs()

	// 1. Extract server binary to temp directory (~16 MB)
	tempDir, serverPath, serverCleanup, err := extractServerToTemp()
	if err != nil {
		log.Fatalf("Extract server: %v", err)
	}
	defer func() {
		if serverCleanup != nil {
			serverCleanup()
		}
	}()

	// 1.5 Auto-detect devices (GPU + NPU) if user didn't specify --device
	deviceHint := detectDevices(serverPath, tempDir)

	// 2. Resolve model: sidecar .gguf → embedded → download
	exePath, _ := os.Executable()
	modelSrc, err := resolveModel(exePath)
	if err != nil {
		log.Fatalf("Resolve model: %v", err)
	}

	// Print banner now that we know the model source
	var loadMethod string
	switch modelSrc.method {
	case "embedded":
		loadMethod = "mmap (zero-copy)"
	case "sidecar":
		loadMethod = "sidecar file"
	case "downloaded", "cached":
		loadMethod = "local file"
	default:
		loadMethod = modelSrc.method
	}
	fmt.Println()
	fmt.Println("  Ollama Local - Self-contained LLM Server")
	fmt.Printf("  Model: %s via %s (%.0f MB)\n", displayName, loadMethod, modelSrc.sizeMB)
	fmt.Println("  Server: http://127.0.0.1:11434")
	fmt.Println()

	serverArgs := buildServerArgs(serverOverrides, deviceHint, modelSrc)

	// 3. Start llama-server
	serverCmd, err := startServer(serverPath, modelSrc, serverArgs)
	if err != nil {
		log.Fatalf("Start server: %v", err)
	}

	// 4. Graceful shutdown — always clean up temp files
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)

	go func() {
		<-sigChan
		log.Println("\nShutting down...")
		if serverCmd != nil && serverCmd.Process != nil {
			serverCmd.Process.Kill()
			serverCmd.Wait()
		}
		serverCleanup()
		os.Exit(0)
	}()

	// 5. Warm-up inference — load tensors into GPU memory before user starts
	log.Println("Warming up model (loading tensors)...")
	warmupInference()

	// 5.5 Open the UI in the default browser
	openBrowser("http://127.0.0.1:11434")

	// 6. Interactive chat or server-only mode
	fi, _ := os.Stdin.Stat()
	isPipe := (fi.Mode() & os.ModeNamedPipe) != 0
	if !isPipe || runtime.GOOS == "windows" {
		chatClient()
	} else {
		log.Println("No TTY — running in server-only mode")
		log.Printf("API: http://%s/v1/chat/completions", serverAddr)
		log.Println("Press Ctrl+C to stop")
		<-sigChan
	}

	if serverCmd != nil && serverCmd.Process != nil {
		serverCmd.Process.Kill()
		serverCmd.Wait()
	}
	log.Println("Server stopped.")
}
