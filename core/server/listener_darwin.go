//go:build darwin

package server

import (
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// peerAllowed accepts only connections from processes running as our own
// user, read from the kernel with LOCAL_PEERCRED.
func peerAllowed(nc net.Conn) bool {
	uc, ok := nc.(*net.UnixConn)
	if !ok {
		return false
	}
	raw, err := uc.SyscallConn()
	if err != nil {
		return false
	}
	var cred *unix.Xucred
	var credErr error
	if err := raw.Control(func(fd uintptr) {
		cred, credErr = unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	}); err != nil || credErr != nil || cred == nil {
		return false
	}
	return cred.Uid == uint32(os.Getuid())
}
