//go:build !darwin

package server

import "net"

// peerAllowed has no peer-credential check off macOS; the socket's 0600 mode
// is the only protection there.
func peerAllowed(net.Conn) bool { return true }
