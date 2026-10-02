package cli

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
)

// THE NODE ABI DECLARATION — THE PACKER'S HALF.
//
// The BOX's half is stated once, in the header block of deploy/site-deploy-node.sh
// and in deploy/README.md "The node runtime target: the same arm, plus a declared
// ABI". This file is the other end of that wire and deliberately transcribes the
// contract rather than inventing a second one:
//
//	<artifact-root>/.bp-node-abi
//	node_major=<integer>
//	libc=glibc|musl|unknown
//
// Both keys are REQUIRED. Unknown keys are IGNORED (forward compatibility — a
// packer that adds a key must not brick an older box), the file is read at most
// 16 lines deep, and the LAST assignment of a key wins. The engine refuses a
// tree with no declaration, or one whose node_major is not a bare integer, with
// exit 17 BEFORE STAGE — nothing staged, no slot booted.
//
// WHY THE CLI EMITS IT RATHER THAN ASKING THE USER. A node release is a PROCESS:
// a traced `node_modules` can carry compiled native addons (.node) bound to one
// NODE_MODULE_VERSION and one C library. Bytes built on node 22/glibc that boot
// on node 20/musl do not 404, they abort at require(). The only host that knows
// what the addons were built against is the one that built them, and that is the
// host running `bp cloud site deploy --prebuilt`. So bp declares it.
//
// `unknown` IS A SUPPORTED VALUE FOR libc, NOT A COP-OUT. There is no portable
// "what libc am I" call; the box's own answer is an `ldd` heuristic. The matching
// rule is asymmetric on purpose: node_major must match EXACTLY, while a libc
// mismatch refuses only when BOTH sides name a real libc. An `unknown` on either
// side is UNDECIDED and does not refuse — a heuristic that cannot tell must not
// manufacture a refusal out of its own ignorance. The node_major half still
// binds, so the arm is never vacuous.
//
// node_major HAS NO `unknown`. A packer that cannot name the node it built with
// is refused HERE, in the CLI, with the export to set — because a declaration of
// `node_major=unknown` is refused by the box at PLAN, after the nonced mint and
// the upload have already been spent.
const nodeABIMarkName = ".bp-node-abi"

// nodeABIMaxLines mirrors the engine's `NR<=16` read bound (abi_decl_value in
// deploy/site-deploy-node.sh). A declaration this side would read past that is a
// declaration the box would read differently, which is the one thing the two
// halves of a wire contract may never do.
const nodeABIMaxLines = 16

// nodeABILibc* are the whole libc vocabulary. Anything else is a declaration the
// box has no arm for.
const (
	nodeABILibcGlibc   = "glibc"
	nodeABILibcMusl    = "musl"
	nodeABILibcUnknown = "unknown"
)

// nodeABI is one declaration. Major is an int rather than a string precisely
// because the engine refuses a non-integer: making it unrepresentable here means
// the refusal cannot be reached by a value this type produced.
type nodeABI struct {
	Major int
	Libc  string
}

// render emits the file the box reads. LF-separated, trailing newline, both keys
// present — the shape the header block states.
func (a nodeABI) render() []byte {
	return []byte(fmt.Sprintf("node_major=%d\nlibc=%s\n", a.Major, a.Libc))
}

// nodeABIProbe is the injection seam. The real one shells out; the tests hand in
// canned answers so every branch below is reachable without a node on PATH and
// without an ldd — including the branches THIS host cannot produce.
type nodeABIProbe struct {
	// GOOS is the packing host's OS. Only "linux" has a glibc/musl answer to
	// give; everywhere else the honest value is `unknown`.
	GOOS string
	// LookupEnv is os.LookupEnv in production.
	LookupEnv func(string) (string, bool)
	// NodeVersion answers what `node -v` prints ("v22.11.0"), or an error.
	NodeVersion func() (string, error)
	// LddVersion answers what `ldd --version` prints on stdout+stderr. An error
	// is not fatal: it means the probe could not tell, which is `unknown`.
	LddVersion func() (string, error)
}

// defaultNodeABIProbe is the production probe.
func defaultNodeABIProbe() nodeABIProbe {
	return nodeABIProbe{
		GOOS:      runtime.GOOS,
		LookupEnv: os.LookupEnv,
		NodeVersion: func() (string, error) {
			bin, err := exec.LookPath("node")
			if err != nil {
				return "", err
			}
			out, err := exec.Command(bin, "-v").Output()
			return string(out), err
		},
		LddVersion: func() (string, error) {
			out, err := exec.Command("ldd", "--version").CombinedOutput()
			return string(out), err
		},
	}
}

// nodeABIMajorEnv / nodeABILibcEnv are the two overrides.
//
// BARKPARK_NODE_LIBC is NOT a new name: it is the engine's own override for a
// box whose ldd probe cannot tell (deploy/site-deploy-node.sh, box_node_libc).
// One name, one meaning, on both ends of the wire — a packer and a box that
// spell the same escape hatch differently is exactly the drift this contract
// exists to prevent.
const (
	nodeABIMajorEnv = "BARKPARK_NODE_ABI_MAJOR"
	nodeABILibcEnv  = "BARKPARK_NODE_LIBC"
)

// probeNodeABI answers what this host built against, or the refusal to say so.
//
// The ORDER is override-then-probe for both keys, and the override wins outright:
// a CI runner that packs a tree built inside a container knows an answer its own
// `node -v` does not have, and the alternative — declaring the packer's node and
// shipping a lie — is the failure this whole file exists to prevent.
func probeNodeABI(p nodeABIProbe) (nodeABI, error) {
	major, err := probeNodeABIMajor(p)
	if err != nil {
		return nodeABI{}, err
	}
	return nodeABI{Major: major, Libc: probeNodeABILibc(p)}, nil
}

func probeNodeABIMajor(p nodeABIProbe) (int, error) {
	if raw, ok := p.LookupEnv(nodeABIMajorEnv); ok && strings.TrimSpace(raw) != "" {
		v := strings.TrimSpace(raw)
		n, cerr := strconv.Atoi(v)
		if cerr != nil || n <= 0 || n > 999 {
			return 0, fmt.Errorf("%s is %q — it must be a bare positive integer node major (e.g. %s=22); the box reads this value out of %s and refuses anything that is not an integer (exit 17, before anything is staged)", nodeABIMajorEnv, v, nodeABIMajorEnv, nodeABIMarkName)
		}
		return n, nil
	}
	raw, verr := p.NodeVersion()
	major, ok := parseNodeMajor(raw)
	if !ok {
		detail := "no `node` on PATH"
		if verr == nil {
			detail = fmt.Sprintf("`node -v` printed %q, which is not a vNN.x.y version", strings.TrimSpace(sanitizeCell(raw)))
		}
		return 0, fmt.Errorf("cannot name the node major these bytes were built against (%s) — a node artifact must DECLARE it in %s at the root of the packed tree, and the box refuses an undeclared or non-integer ABI at PLAN (exit 17) after the upload is already spent. Either run this from the environment that built the tree, or state it: export %s=22", detail, nodeABIMarkName, nodeABIMajorEnv)
	}
	return major, nil
}

// parseNodeMajor reads `v22.11.0` the way the box's box_node_major does — strip
// a leading `v`, take everything before the first dot — and answers false rather
// than guessing on anything else.
func parseNodeMajor(raw string) (int, bool) {
	v := strings.TrimSpace(raw)
	if !strings.HasPrefix(v, "v") {
		return 0, false
	}
	v = v[1:]
	if i := strings.IndexByte(v, '.'); i >= 0 {
		v = v[:i]
	}
	if v == "" || len(v) > 3 {
		return 0, false
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 {
		return 0, false
	}
	return n, true
}

// probeNodeABILibc NEVER fails. Every way of not knowing lands on `unknown`,
// which the contract makes undecided rather than refusing — see the header.
func probeNodeABILibc(p nodeABIProbe) string {
	if raw, ok := p.LookupEnv(nodeABILibcEnv); ok {
		switch strings.ToLower(strings.TrimSpace(raw)) {
		case nodeABILibcGlibc:
			return nodeABILibcGlibc
		case nodeABILibcMusl:
			return nodeABILibcMusl
		case nodeABILibcUnknown:
			return nodeABILibcUnknown
		}
		// An override this binary cannot read is NOT passed through to the wire:
		// the box's vocabulary is three words, and a fourth would either refuse
		// on the box or (worse) be compared as a literal against `glibc`.
	}
	// macOS and Windows link neither glibc nor musl. Declaring either would be a
	// guess the box would then MATCH against, turning a non-answer into a false
	// agreement; `unknown` is the value the contract provides for exactly this.
	if p.GOOS != "linux" {
		return nodeABILibcUnknown
	}
	out, err := p.LddVersion()
	if err != nil && strings.TrimSpace(out) == "" {
		return nodeABILibcUnknown
	}
	low := strings.ToLower(out)
	switch {
	case strings.Contains(low, "musl"):
		return nodeABILibcMusl
	case strings.Contains(low, "gnu libc"), strings.Contains(low, "glibc"), strings.Contains(low, "gnu c library"):
		return nodeABILibcGlibc
	default:
		return nodeABILibcUnknown
	}
}

// readNodeABIDeclaration parses a declaration the SAME WAY the engine does:
// at most 16 lines, split on the FIRST `=`, unknown keys ignored, LAST
// assignment of a key wins. It returns the two raw values so the caller can
// judge them against the engine's own rules rather than a paraphrase.
//
// It is deliberately a transcription of abi_decl_value, not an improvement on
// it: a packer that reads its own file more generously than the box does will
// wave through a declaration the box refuses, which is the exact failure the
// pre-upload check exists to prevent.
func readNodeABIDeclaration(body string) (major, libc string) {
	lines := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
	for i, line := range lines {
		if i >= nodeABIMaxLines {
			break
		}
		eq := strings.IndexByte(line, '=')
		if eq < 0 {
			continue
		}
		key := line[:eq]
		val := strings.TrimSpace(strings.TrimSuffix(line[eq+1:], "\r"))
		switch key {
		case "node_major":
			if val != "" {
				major = val
			}
		case "libc":
			if val != "" {
				libc = val
			}
		}
	}
	return major, libc
}

// nodeABIDeclarationFault judges an EXISTING declaration against the engine's
// refusals and answers "" when the box would accept it.
//
// This is the "carries a declaration the ENGINE accepts" half, applied to a file
// the packer did not write: a tree that already carries `.bp-node-abi` keeps it
// (a CI runner that cross-builds knows an answer the packing host does not), but
// it is judged here, before the nonced mint, instead of on the box after the
// upload. The two refusals below are exactly the two the engine raises for a
// present-but-unusable declaration — a non-integer node_major and a missing
// libc line.
func nodeABIDeclarationFault(path, body string) string {
	major, libc := readNodeABIDeclaration(body)
	if _, ok := nodeABIIntegerMajor(major); !ok {
		have := major
		if have == "" {
			have = "<missing>"
		}
		return fmt.Sprintf("%s declares node_major=%q, but the box wants a bare integer (e.g. node_major=22) and refuses anything else at PLAN with exit 17 — before anything is staged and after this upload is already spent", path, sanitizeCell(have))
	}
	if libc == "" {
		return fmt.Sprintf("%s declares no libc= line — both keys are required (node_major and libc), and the box refuses a half-declaration at PLAN with exit 17. Use libc=%s only when the packer genuinely cannot tell", path, nodeABILibcUnknown)
	}
	return ""
}

// nodeABIIntegerMajor mirrors the engine's integer test verbatim: non-empty, at
// most three characters, every character a digit.
func nodeABIIntegerMajor(v string) (int, bool) {
	if v == "" || len(v) > 3 {
		return 0, false
	}
	for i := 0; i < len(v); i++ {
		if v[i] < '0' || v[i] > '9' {
			return 0, false
		}
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return 0, false
	}
	return n, true
}

// nodeABIExtraFor decides what (if anything) the packer must ADD to a node
// artifact, and refuses a tree whose own declaration the box would not accept.
//
// Three outcomes, and the middle one is the reason this is not just "always
// write the file":
//
//   - the tree carries NO declaration -> synthesize one from this host.
//   - the tree carries one the box ACCEPTS -> leave it alone (nil extra). A
//     packing host is not always the building host, and overwriting a
//     cross-build's honest declaration with the laptop's would ship a lie the
//     box then certifies.
//   - the tree carries one the box would REFUSE -> refuse HERE, naming the
//     fault, rather than after the nonced mint and the upload.
func nodeABIExtraFor(abs string, probe nodeABIProbe) ([]tarballExtraFile, error) {
	path := filepath.Join(abs, nodeABIMarkName)
	if raw, err := os.ReadFile(path); err == nil {
		if fault := nodeABIDeclarationFault(nodeABIMarkName, string(raw)); fault != "" {
			return nil, fmt.Errorf("%s", fault)
		}
		return nil, nil
	} else if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read %s: %w", path, err)
	}
	abi, err := probeNodeABI(probe)
	if err != nil {
		return nil, err
	}
	return []tarballExtraFile{{Name: nodeABIMarkName, Body: abi.render()}}, nil
}
