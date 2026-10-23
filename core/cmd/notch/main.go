// Command notch is the PlatyNotch core: the socket server the Mac app talks
// to, the hook client agents run, and a small CLI. See `notch help`.
package main

import (
	"context"
	"os"

	"github.com/Vaibhaav-Tiwari/PlatyNotch/core/cli"
)

func main() {
	os.Exit(cli.Run(context.Background(), os.Args[1:]))
}
