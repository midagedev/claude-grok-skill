//go:build unix

package statusline

import "syscall"

// A new session, so the refresher is not in this render's process group and
// cannot be killed with it. The status line is re-invoked constantly and each
// invocation is short-lived; a child that dies with its parent would never
// finish a one-to-two-second quota fetch.
func detachAttr() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setsid: true} }
