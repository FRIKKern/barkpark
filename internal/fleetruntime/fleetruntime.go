// Package fleetruntime is the ONE definition of the fleet listener runtime a
// support box installs under /opt/barkpark-fleet: which files, fetched how,
// pinned to which commit, recorded where. Both chains that bring a support box
// up build their runtime step here:
//
//   - internal/cli (bp cloud support add, and bp cloud support refresh)
//   - internal/provisioner (the server-side provision_support chain)
//
// Before this package the two carried byte-identical copies of the fetch
// script; #19994 changed only the CLI copy, so provisioner-chain boxes shipped
// no bp-read.sh beside the runner and no fleet-run.version, and never reported
// capacity.runner_sha (task-837f1013efdf100f). The provisioner may not import
// internal/cli (its HARD LAW), so the shared definition lives here, importing
// only the cloud step type both already use.
package fleetruntime

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cli/cloud"
)

// RawRoot is the repo's raw-content root WITHOUT a ref, so the runtime can be
// fetched at a PINNED commit sha (<root>/<sha>/<path>) — a sha URL is
// immutable, which is what lets the runner report the exact version it was
// written from.
const RawRoot = "https://raw.githubusercontent.com/FRIKKern/barkpark"

// MainSHAURL answers origin/main's commit sha as plain text under the
// vnd.github.sha media type.
const MainSHAURL = "https://api.github.com/repos/FRIKKern/barkpark/commits/main"

// Dir is where the runtime lives on a support box.
const Dir = "/opt/barkpark-fleet"

// File is one runtime file: its repo path and the name it lands under in Dir.
type File struct{ Repo, Name string }

// Files is the runtime file set. bp-read.sh rides BESIDE the runner: since
// #16050 fleet-run.sh sources scripts/lib/bp-read.sh, and from Dir its
// repo-relative path (../../scripts/lib) does not exist — without it bp_json
// is undefined and the listener idles forever while still beating online.
// fleet-run.sh still falls back to /opt/barkpark/scripts/lib/bp-read.sh.
var Files = []File{
	{"tooling/fleet/fleet-run.sh", "fleet-run.sh"},
	{"tooling/fleet/fleet-protocol.md", "fleet-protocol.md"},
	{"scripts/lib/bp-read.sh", "bp-read.sh"},
}

// VersionFile is written beside the runner with the sha the files came from;
// fleet-run.sh reports it as capacity.runner_sha on every beat.
const VersionFile = "fleet-run.version"

// SHARe fences a resolved commit before it is single-quoted into the on-box
// script and printed as the version: exactly 40 lowercase hex.
var SHARe = regexp.MustCompile(`^[0-9a-f]{40}$`)

// ResolveMainSHA resolves origin/main to a commit sha from the CALLER's
// machine (the operator's laptop for the CLI, the control-plane worker for the
// provisioner). Bounded to 15s and a 4 KiB body.
func ResolveMainSHA(ctx context.Context) (string, error) {
	ctx, cancel := context.WithTimeout(ctx, 15*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, MainSHAURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("Accept", "application/vnd.github.sha")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 4097))
	if err != nil {
		return "", err
	}
	if len(body) > 4096 {
		return "", fmt.Errorf("%s answered more than 4096 bytes — refusing to parse a truncated body", MainSHAURL)
	}
	if resp.StatusCode != http.StatusOK {
		return "", fmt.Errorf("%s answered %d: %s", MainSHAURL, resp.StatusCode, trim(body))
	}
	sha := strings.TrimSpace(string(body))
	if !SHARe.MatchString(sha) {
		return "", fmt.Errorf("%s answered an unexpected sha shape %q", MainSHAURL, trim(body))
	}
	return sha, nil
}

func trim(b []byte) string {
	s := strings.TrimSpace(string(b))
	if len(s) > 200 {
		s = s[:200] + "…"
	}
	return s
}

// FilesStep writes the runtime from origin/main CONTENT (never an operator
// machine's stale copy).
//
//   - sha != "": every file is fetched from RawRoot AT THAT COMMIT
//     (immutable), and VersionFile records the sha.
//   - checkoutFallback: when the pinned fetch fails (or sha == ""), copy the
//     files from the freshened on-box checkout (/opt/barkpark) instead, and
//     record ITS HEAD. Bring-ups allow this (a GitHub outage must not kill
//     one); refresh does NOT — a refresh that cannot write the sha it printed
//     fails.
//
// All files land as *.bpnew and are mv'd into place (a new inode), never
// written in place: bash reads a running script by offset, so truncating
// fleet-run.sh under a live listener would feed it a spliced file. The files
// are all-or-nothing per source — a mix of pinned and checkout content would
// make the version file lie.
//
// Callers fence sha with SHARe before it reaches here; FilesStep refuses to
// embed anything else (it builds a step that fails on the box instead).
func FilesStep(sha string, checkoutFallback bool) cloud.CaddyStep {
	if sha != "" && !SHARe.MatchString(sha) {
		return cloud.CaddyStep{
			Title: "write the fleet runtime (refused: unfenced sha)",
			Argv:  []string{"bash", "-lc", "echo 'fleet runtime: refusing an unfenced sha' >&2; exit 1"},
		}
	}
	fb := "0"
	if checkoutFallback {
		fb = "1"
	}
	pairs := make([]string, 0, len(Files))
	names := make([]string, 0, len(Files))
	for _, f := range Files {
		pairs = append(pairs, f.Repo+":"+f.Name)
		names = append(names, f.Name)
	}
	script := `set -e
d=` + Dir + `
mkdir -p "$d"
sha='` + sha + `'
files='` + strings.Join(pairs, " ") + `'
pull(){ for f in $files; do curl -fsSL "` + RawRoot + `/$sha/${f%%:*}" -o "$d/${f#*:}.bpnew" 2>/dev/null || return 1; done; }
copy(){ for f in $files; do cp "/opt/barkpark/${f%%:*}" "$d/${f#*:}.bpnew" || return 1; done; }
if [ -n "$sha" ] && pull; then ver="$sha"
elif [ ` + fb + ` = 1 ] && copy; then ver="$(git -C /opt/barkpark rev-parse HEAD 2>/dev/null)" || ver=unknown
else rm -f "$d"/*.bpnew; echo "fleet runtime: cannot fetch the runner at ${sha:-the checkout}" >&2; exit 1
fi
chmod 0755 "$d/fleet-run.sh.bpnew"
for f in $files; do mv -f "$d/${f#*:}.bpnew" "$d/${f#*:}"; done
printf '%s\n' "$ver" > "$d/` + VersionFile + `.bpnew"
mv -f "$d/` + VersionFile + `.bpnew" "$d/` + VersionFile + `"`
	title := "write " + strings.Join(names, " + ") + " from origin/main content"
	if sha != "" {
		title += " at " + sha
	}
	return cloud.CaddyStep{
		Title: title,
		Argv:  []string{"bash", "-lc", script},
	}
}
