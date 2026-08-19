//go:build unix

package runs

import "syscall"

// Signal 0 is the liveness probe: it performs error checking but sends
// nothing. Isolated behind a build tag so the package states its platform
// assumption instead of failing to compile somewhere with a bare syscall.
const sysSignalZero = syscall.Signal(0)
