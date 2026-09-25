package cloud

import (
	"context"
	"strings"
)

// jpf-bl-siteplane-verify-probe — WHY a step-7c site-plane install failed.
//
// Step 7c's installer (deploy/site-runtime-install.sh) exiting non-zero is one
// bit. The verify gate now FAILS a box on that bit, so the failure has to say
// two more things or an upstream apt / nixpacks outage reads as a box fault:
//
//   - WHICH components are missing — measured on the box right after the
//     failed install, by the same seven checks the agent's site_plane beat
//     makes (internal/agent/site_plane.go), named in the same words;
//   - the TAIL of the installer's own log, so "E: Failed to fetch …" or a
//     curl 5xx from the nixpacks installer is visible verbatim.

// sitePlaneComponentScript prints one `name=1|0` line per component. It is
// read-only (command -v / version / systemctl is-active) and carries no secret.
// SITEPLANE_PROBE is the marker a test runner keys on.
const sitePlaneComponentScript = `# SITEPLANE_PROBE
command -v docker >/dev/null 2>&1 && echo docker=1 || echo docker=0
docker buildx version >/dev/null 2>&1 && echo buildx=1 || echo buildx=0
command -v nixpacks >/dev/null 2>&1 && echo nixpacks=1 || echo nixpacks=0
[ -x /usr/local/go/bin/go ] && echo go=1 || echo go=0
command -v git >/dev/null 2>&1 && echo git=1 || echo git=0
systemctl is-active --quiet barkpark-builder.service && echo builder_unit=1 || echo builder_unit=0
systemctl is-active --quiet barkpark-runtime.service && echo runtime_unit=1 || echo runtime_unit=0
`

// sitePlaneComponents is the probe's key order and the human word each is
// named by — the same seven, in the same words, as the agent beat's verdict.
var sitePlaneComponents = []struct{ key, word string }{
	{"docker", "docker"},
	{"buildx", "buildx"},
	{"nixpacks", "nixpacks"},
	{"go", "go toolchain"},
	{"git", "git"},
	{"builder_unit", "builder unit"},
	{"runtime_unit", "runtime unit"},
}

// sitePlaneLogTailLines / sitePlaneLogTailBytes bound the installer log tail
// that rides into the verify failure (and from there the /fail POST).
const (
	sitePlaneLogTailLines = 6
	sitePlaneLogTailBytes = 480
)

// diagnoseSitePlane measures the components after a failed install and returns
// the ones that are MISSING (measured 0) and UNMEASURED (no line came back, or
// the probe could not run at all). A runner without the capture capability
// leaves every component unmeasured — never "missing": nobody looked.
func diagnoseSitePlane(ctx context.Context, runner StepRunner) (missing, unmeasured []string) {
	seen := map[string]string{}
	if cmd, ok := runner.(hostCommandRunner); ok {
		if out, err := cmd.RunOutput(ctx, sitePlaneComponentScript); err == nil {
			for _, line := range strings.Split(out, "\n") {
				if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok {
					seen[k] = v
				}
			}
		}
	}
	for _, c := range sitePlaneComponents {
		switch seen[c.key] {
		case "1":
		case "0":
			missing = append(missing, c.word)
		default:
			unmeasured = append(unmeasured, c.word)
		}
	}
	return missing, unmeasured
}

// sitePlaneLogTail keeps the last sitePlaneLogTailLines non-empty lines of the
// installer's failure text (SSHStepRunner.Run folds the scrubbed captured
// output into its error), bounded to sitePlaneLogTailBytes from the END — the
// last lines are where an installer says why it stopped.
func sitePlaneLogTail(failure string) string {
	var lines []string
	for _, l := range strings.Split(failure, "\n") {
		if l = strings.TrimSpace(l); l != "" {
			lines = append(lines, l)
		}
	}
	if len(lines) > sitePlaneLogTailLines {
		lines = lines[len(lines)-sitePlaneLogTailLines:]
	}
	tail := strings.Join(lines, " | ")
	if len(tail) > sitePlaneLogTailBytes {
		tail = "…" + strings.ToValidUTF8(tail[len(tail)-sitePlaneLogTailBytes:], "")
	}
	return tail
}
