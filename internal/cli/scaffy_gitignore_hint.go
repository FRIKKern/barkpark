package cli

// scaffy_gitignore_hint.go is the adoption greeting for a FOREIGN repo's first
// `bp scaffy pull` (D108 replaced the cut `init` verb with exactly this).
//
// The gap it closes: `bp scaffy run` writes ephemeral receipts under
// <root>/.scaffy/ (D35). Barkpark's own .gitignore carries the `.scaffy/` line,
// a stranger's does not — so the first run in an adopted repo quietly stages
// receipts for commit. pull is the one moment we know a stranger is adopting
// scaffy, so pull greets them: PRINT-ONLY, never a write to their .gitignore.
//
// Two properties the greeting has to keep, or it is noise:
//
//  1. QUIET WHEN ALREADY HANDLED. A repo that already ignores .scaffy/ hears
//     nothing, ever — not even on the first pull. The question asked is "does
//     git ignore this path", answered by `git check-ignore` when git is there
//     (it sees .gitignore at any depth, .git/info/exclude and core.excludesFile
//     alike), falling back to a literal <root>/.gitignore scan when it is not.
//
//  2. ONE-TIME. The already-greeted bit lives in the USER's config dir —
//     {UserConfigDir}/barkpark/scaffy/gitignore-hint-<sha1(abs root)> — the same
//     shape cmux stamps use. It is deliberately NOT in the adopted repo:
//     .scaffy/ is the receipts lifecycle (wiped freely, and the very directory
//     the hint says is unignored — pull writing there would contradict the
//     sidecar rule), and scaffy/commands/ is COMMITTED, so a marker there would
//     travel to every teammate who never saw the hint.
//
// Honesty when the store is missing: a cleared config dir re-greets once — the
// adopter's state was reset, so re-asking is correct. The failure direction is
// fixed the safe way: the hint PRINTS FIRST and the marker is written after, so
// an unwritable config dir means "greet again next pull" (mildly noisy), never
// "silently never greet again".

import (
	"bufio"
	"crypto/sha1"
	"encoding/hex"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// scaffyStoreDir is the receipts store the hint is about (D35).
const scaffyStoreDir = ".scaffy"

// scaffyGitignoreHintText is the greeting itself. Print-only advice.
const scaffyGitignoreHintText = "add " + scaffyStoreDir + "/ to your .gitignore — `bp scaffy run` writes ephemeral receipts there"

// maybePrintScaffyGitignoreHint prints the one-time adoption hint when root's
// git ignore rules do NOT cover .scaffy/ and this machine has not greeted this
// root before. Silent otherwise. Never writes anything under root.
func maybePrintScaffyGitignoreHint(out *writer, root string) {
	if scaffyStoreIsIgnored(root) {
		return
	}
	marker, err := scaffyGitignoreHintMarker(root)
	if err == nil && marker != "" {
		if _, serr := os.Stat(marker); serr == nil {
			return // already greeted this root on this machine
		}
	}
	out.outf("● %s", scaffyGitignoreHintText)
	out.outf("  (said once per repo; pull never edits your .gitignore)")
	if err != nil || marker == "" {
		return
	}
	// Best effort: a failed mark means the next pull greets again, which is the
	// honest failure direction. Never suppress on a write we could not make.
	if mkerr := os.MkdirAll(filepath.Dir(marker), 0o755); mkerr != nil {
		return
	}
	_ = os.WriteFile(marker, []byte(root+"\n"), 0o644)
}

// scaffyGitignoreHintMarker is {UserConfigDir}/barkpark/scaffy/gitignore-hint-<sha1(abs root)>.
// Keyed by the ABSOLUTE root so two checkouts of the same project are two
// adoptions, and a relative cwd cannot alias a different tree's marker.
func scaffyGitignoreHintMarker(root string) (string, error) {
	base, err := userConfigDir()
	if err != nil || base == "" {
		return "", errors.New("no user config dir")
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", err
	}
	sum := sha1.Sum([]byte(abs))
	return filepath.Join(base, "barkpark", "scaffy", "gitignore-hint-"+hex.EncodeToString(sum[:])), nil
}

// scaffyStoreIsIgnored answers "would git ignore <root>/.scaffy/?".
//
// git is the authority when it answers: `git check-ignore -q` exits 0 for an
// ignored path and 1 for a tracked/unignored one, and it consults every ignore
// source (nested .gitignore files, .git/info/exclude, core.excludesFile) — a
// literal read of <root>/.gitignore sees only one of them. Any other exit (128
// outside a work tree, git absent from PATH) is NOT an answer, so we fall back
// to the literal scan rather than guessing.
func scaffyStoreIsIgnored(root string) bool {
	if ignored, ok := scaffyStoreIsIgnoredByGit(root); ok {
		return ignored
	}
	return scaffyStoreIsIgnoredByFile(filepath.Join(root, ".gitignore"))
}

// scaffyGitignoreCheckRunner is swapped in tests to prove BOTH arms (git
// answering, and git declining to answer) without depending on the machine.
var scaffyGitignoreCheckRunner = func(root string) (int, error) {
	cmd := exec.Command("git", "-C", root, "check-ignore", "-q", "--no-index", scaffyStoreDir+"/")
	// A hostile or misconfigured environment must not hang the CLI on a prompt.
	cmd.Env = append(os.Environ(), "GIT_TERMINAL_PROMPT=0", "GIT_OPTIONAL_LOCKS=0")
	err := cmd.Run()
	if err == nil {
		return 0, nil
	}
	var ee *exec.ExitError
	if errors.As(err, &ee) {
		return ee.ExitCode(), nil
	}
	return -1, err
}

// scaffyStoreIsIgnoredByGit returns (ignored, answered).
func scaffyStoreIsIgnoredByGit(root string) (bool, bool) {
	code, err := scaffyGitignoreCheckRunner(root)
	if err != nil {
		return false, false
	}
	switch code {
	case 0:
		return true, true
	case 1:
		return false, true
	default:
		return false, false // 128 = not a work tree; anything else is not an answer
	}
}

// scaffyStoreIsIgnoredByFile scans a literal .gitignore for a .scaffy entry.
// Deliberately narrow: it recognises the handful of spellings a human writes
// for a directory ignore (`.scaffy`, `.scaffy/`, `/.scaffy`, `.scaffy/*`,
// `**/.scaffy`) and honours a later negation (`!.scaffy`), which is exactly the
// set `git check-ignore` would have settled had git been available. A missing
// file is simply "not ignored".
func scaffyStoreIsIgnoredByFile(path string) bool {
	f, err := os.Open(path)
	if err != nil {
		return false
	}
	defer f.Close()

	ignored := false
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		negate := strings.HasPrefix(line, "!")
		if negate {
			line = strings.TrimSpace(line[1:])
		}
		if !scaffyGitignoreLineMatchesStore(line) {
			continue
		}
		// Last matching rule wins, exactly like git.
		ignored = !negate
	}
	return ignored
}

// scaffyGitignoreLineMatchesStore reports whether one .gitignore pattern names
// the .scaffy store directory.
func scaffyGitignoreLineMatchesStore(line string) bool {
	line = strings.TrimSuffix(line, "/*")
	line = strings.TrimSuffix(line, "/**")
	line = strings.TrimSuffix(line, "/")
	line = strings.TrimPrefix(line, "**/")
	line = strings.TrimPrefix(line, "/")
	return line == scaffyStoreDir
}
