// Command dump renders a Bulldocs paper fixture straight to stdout at a fixed
// width — the non-interactive twin of cmd/demo, for verification scripts.
//
// Usage:
//
//	go run ./internal/pdrender/cmd/dump <paper.json> [width]
package main

import (
	"fmt"
	"os"
	"strconv"

	"github.com/FRIKKern/barkpark/internal/pdrender"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: dump <paper.json> [width]")
		os.Exit(2)
	}
	raw, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "read %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}
	blocks, err := pdrender.Decode(raw)
	if err != nil {
		fmt.Fprintf(os.Stderr, "decode %s: %v\n", os.Args[1], err)
		os.Exit(1)
	}
	width := 80
	if len(os.Args) > 2 {
		if w, err := strconv.Atoi(os.Args[2]); err == nil && w > 0 {
			width = w
		}
	}
	reg := pdrender.DefaultRegistry(pdrender.DarkTheme())
	ctx := pdrender.RenderCtx{Width: width, Theme: pdrender.DarkTheme(), Profile: pdrender.ANSI256}
	fmt.Println(reg.RenderDoc(blocks, ctx))
}
