// Package hostguard pins the hostnames this repo is allowed to print at
// operators, and scans the working tree for the ones it is not.
//
// WHY THIS EXISTS. Seven `--control-url https://cloud.barkpark<dot>dev`
// examples sat across five Go files — doc comments and flag help, the strings
// an operator copies verbatim — naming a domain this project has never served.
// The console-side siblings were fixed once and rotted straight back, because
// the fix shipped with nothing checking it. The strings are not the
// deliverable; this scan is. It reds the moment a banned host returns.
//
// The canonical control-plane origin is https://barkpark.cloud —
// deploy/cp-deploy.sh rewrites the live provisioner unit's --control-url to
// exactly that value (PROVISIONER_CONTROL_URL default), and deploy.yml smokes
// https://barkpark.cloud/ and /v1/auth/login. Not inherited from a doc: that
// is the value the running box gets.
package hostguard

import (
	"bufio"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// Banned lists hostnames that must not appear anywhere in the tree.
//
// Each entry is ASSEMBLED FROM FRAGMENTS ON PURPOSE. A literal here would be a
// hit on itself: the guard would match its own source, and the plain
// `git grep -c <host>` an operator runs to confirm the tree is clean would
// return 1 forever and stop meaning anything. Concatenation keeps the literal
// absent from every byte of the repo while the scan still looks for it.
var Banned = []string{
	"cloud.barkpark" + ".dev", // never a domain this project served
}

// skipDirs are build output, vendored code and VCS internals. Nothing an
// operator reads, and scanning them costs seconds.
var skipDirs = map[string]bool{
	".git": true, "node_modules": true, "_build": true, "deps": true,
	"vendor": true, ".turbo": true, ".elixir_ls": true, "dist": true,
	".next": true, "cover": true, ".pi": true, ".pi-flow": true,
	".barkpark": true,
}

// maxFileBytes skips anything too large to be prose an operator copies from.
const maxFileBytes = 4 << 20

// Hit is one banned hostname found at one line.
type Hit struct {
	Path string // path relative to the scan root
	Line int    // 1-indexed
	Host string // the banned entry that matched
	Text string // the offending line, trimmed
}

func (h Hit) String() string {
	return fmt.Sprintf("%s:%d: banned host %q in: %s", h.Path, h.Line, h.Host, h.Text)
}

// Scan walks root and returns every occurrence of every banned hostname.
// A nil slice means the tree is clean.
func Scan(root string, banned []string) ([]Hit, error) {
	var hits []Hit
	err := filepath.WalkDir(root, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if d.IsDir() {
			if path != root && skipDirs[d.Name()] {
				return filepath.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		if info, ierr := d.Info(); ierr == nil && info.Size() > maxFileBytes {
			return nil
		}
		f, oerr := os.Open(path)
		if oerr != nil {
			return oerr
		}
		defer f.Close()

		rel, rerr := filepath.Rel(root, path)
		if rerr != nil {
			rel = path
		}
		sc := bufio.NewScanner(f)
		sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
		for n := 1; sc.Scan(); n++ {
			line := sc.Text()
			for _, host := range banned {
				if strings.Contains(line, host) {
					text := strings.TrimSpace(line)
					if len(text) > 160 {
						text = text[:160] + "…"
					}
					hits = append(hits, Hit{Path: rel, Line: n, Host: host, Text: text})
				}
			}
		}
		// A binary blob can trip the scanner's line limit; that is not a hit,
		// and it must not abort the walk.
		if sc.Err() != nil {
			return nil
		}
		return nil
	})
	return hits, err
}

// RepoRoot walks up from dir until it finds the directory holding go.mod.
func RepoRoot(dir string) (string, error) {
	abs, err := filepath.Abs(dir)
	if err != nil {
		return "", err
	}
	for {
		if _, serr := os.Stat(filepath.Join(abs, "go.mod")); serr == nil {
			return abs, nil
		}
		parent := filepath.Dir(abs)
		if parent == abs {
			return "", fmt.Errorf("hostguard: no go.mod at or above %s", dir)
		}
		abs = parent
	}
}
