//go:build !darwin

package hookcli

func parentOf(pid int) int { return 0 }

func ttyOf(pid int) string { return "" }
