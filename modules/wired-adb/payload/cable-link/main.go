//go:build linux && arm

// cable-link: wired ADB for a Mac on a head-unit USB host port.
//
// A Mac attached to a USB host presents Apple's NCM network function. This
// service speaks NCM through usbfs, bridges it to a private TAP interface and
// runs one ADB daemon whose only listener is bound to that interface. The
// module runtime starts and stops it (daemon.cable-link in module.properties).
//
// Adapted for HMG-Seogaemo from the contributor's "CN7 Mac USB ADB" package
// (cable-watch 1.0.1, verified on a CN7 KOR 260902 head unit on 2026-11-06).
package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
)

func main() {
	keys := flag.String("keys", "", "adb_keys file with the public keys allowed to connect")
	adbd := flag.String("adbd", "", "packaged cable adbd program")
	flag.Parse()
	if flag.NArg() != 0 || !filepath.IsAbs(*keys) || !filepath.IsAbs(*adbd) {
		fmt.Fprintln(os.Stderr, "usage: cable-link --keys <absolute adb_keys path> --adbd <absolute adbd path>")
		os.Exit(2)
	}
	if err := runService(*adbd, *keys); err != nil {
		fmt.Fprintln(os.Stderr, "STOP:", err)
		os.Exit(1)
	}
}
