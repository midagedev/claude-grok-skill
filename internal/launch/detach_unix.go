//go:build unix

package launch

import "syscall"

// A new session, so a --detach round is not in the caller's process group and
// cannot be killed with it — the exact failure this flag exists for is an
// orchestrator's command timeout TERM-ing the group mid-round.
func detachAttr() *syscall.SysProcAttr { return &syscall.SysProcAttr{Setsid: true} }
