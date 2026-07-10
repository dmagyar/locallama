//go:build !windows

package main

import "os/exec"

func configureWindowsProcess(_ *exec.Cmd) {
	// No-op on non-Windows platforms
}
