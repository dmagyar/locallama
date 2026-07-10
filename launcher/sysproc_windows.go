//go:build windows

package main

import (
	"os/exec"

	"golang.org/x/sys/windows"
)

func configureWindowsProcess(cmd *exec.Cmd) {
	// CREATE_NO_WINDOW prevents a second console window from flashing.
	// Do NOT use DETACHED_PROCESS — it disconnects stdout/stderr,
	// so the user never sees llama-server loading progress or errors.
	cmd.SysProcAttr = &windows.SysProcAttr{
		CreationFlags: windows.CREATE_NO_WINDOW,
	}
}
