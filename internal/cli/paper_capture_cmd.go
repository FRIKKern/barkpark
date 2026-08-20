package cli

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/charmbracelet/lipgloss"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/pdrender"
	"github.com/FRIKKern/barkpark/internal/taskboard"
)

const (
	paperCaptureFormat       = "cycle-release-headless-capture-v1"
	paperCaptureWidthDefault = 120
	paperTUIMaxWidth         = 100
	// Bump this identity whenever the capture parser/render composition changes.
	// It intentionally names code, not candidate bytes; source_digest covers the
	// exact response independently.
	paperCaptureParserIdentity = "bp-paper-capture/pdrender-decode-v1"
)

type paperCaptureArgs struct {
	sourceURL        string
	releaseGateID    string
	waveRevision     string
	candidateID      string
	role             string
	deploymentDigest string
	width            int
}

type paperCaptureProvenance struct {
	Argv             []string `json:"argv"`
	BinaryDigest     string   `json:"binary_digest"`
	DeploymentDigest string   `json:"deployment_digest"`
	ParserDigest     string   `json:"parser_digest"`
	SourceDigest     string   `json:"source_digest"`
	Geometry         string   `json:"geometry"`
	Theme            string   `json:"theme"`
	Profile          string   `json:"profile"`
	Status           int      `json:"status"`
}

type paperCaptureReader struct {
	RawUTF8    string                 `json:"raw_utf8"`
	Provenance paperCaptureProvenance `json:"provenance"`
}

type paperCaptureEnvelope struct {
	Format        string                        `json:"format"`
	ReleaseGateID string                        `json:"release_gate_id"`
	WaveRevision  string                        `json:"wave_revision"`
	CandidateID   string                        `json:"candidate_id"`
	Role          string                        `json:"role"`
	SourceURL     string                        `json:"source_url"`
	Readers       map[string]paperCaptureReader `json:"readers"`
}

func runPaperCapture(out *writer, g globals, args []string) int {
	if g.help {
		usagePaperCapture(out, true)
		return exitOK
	}
	opt, err := parsePaperCaptureArgs(args)
	if err != nil {
		out.userErr("%v", err)
		usagePaperCapture(out, false)
		return exitUsage
	}
	if !g.outputSet || out.output != "json" {
		out.userErr("paper capture requires -o json")
		return exitUsage
	}

	ref, recognized, err := apiclient.ParseReleasePaperRef(opt.sourceURL)
	if err != nil || !recognized {
		if err == nil {
			err = fmt.Errorf("source URL is not a canonical immutable release Paper URL")
		}
		out.userErr("%v", err)
		return exitUsage
	}
	if ref.ReleaseGateID != opt.releaseGateID || ref.RevisionID != opt.waveRevision ||
		ref.CandidateID != opt.candidateID || ref.Role != opt.role {
		out.userErr("source URL pins do not match capture flags")
		return exitUsage
	}

	// The URL is the authority for origin and tenancy. Credentials are inherited
	// only for an explicitly trusted saved/active server, matching paper view's
	// pasted-URL boundary.
	active := resolveContext(g)
	trusted := paperServerTrusted(ref.Origin, active.Server)
	g.server, g.workspace, g.project = ref.Origin, ref.Workspace, ref.Project
	ctx := resolveContext(g)
	if g.token == "" && !trusted {
		ctx.Token = ""
	}
	client := apiclient.New(apiclient.Config{
		BaseURL: ctx.Server, Token: ctx.Token, Workspace: ref.Workspace,
		Project: ref.Project, Dataset: ctx.Dataset, Perspective: paperPerspectiveDefault,
	})
	source, err := client.PaperReleaseSource(ref)
	if err != nil {
		return paperError(out, true, "not_found", "capture immutable Paper: "+err.Error(), exitNotFound)
	}

	readers, err := renderPaperCaptureReaders(source, opt)
	if err != nil {
		return paperError(out, true, "capture_failed", err.Error(), exitGeneric)
	}
	out.renderJSON(paperCaptureEnvelope{
		Format: paperCaptureFormat, ReleaseGateID: ref.ReleaseGateID,
		WaveRevision: ref.RevisionID, CandidateID: ref.CandidateID, Role: ref.Role,
		SourceURL: opt.sourceURL, Readers: readers,
	})
	return exitOK
}

func parsePaperCaptureArgs(args []string) (paperCaptureArgs, error) {
	p := paperCaptureArgs{width: paperCaptureWidthDefault}
	var pos []string
	for i := 0; i < len(args); i++ {
		a := args[i]
		key, inline, hasInline := splitFlagToken(a)
		switch key {
		case "--release-gate", "--wave-revision", "--candidate-id", "--role", "--deployment-digest", "--width":
			v, next, err := flagValue(args, i, inline, hasInline, key)
			if err != nil {
				return p, err
			}
			i = next - 1
			switch key {
			case "--release-gate":
				p.releaseGateID = v
			case "--wave-revision":
				p.waveRevision = v
			case "--candidate-id":
				p.candidateID = v
			case "--role":
				p.role = v
			case "--deployment-digest":
				p.deploymentDigest = v
			case "--width":
				n, err := paperAtoi(v)
				if err != nil {
					return p, fmt.Errorf("invalid --width %q", v)
				}
				if n < pdrender.MinWidth || n > 500 {
					return p, fmt.Errorf("invalid --width %q (want %d..500)", v, pdrender.MinWidth)
				}
				p.width = n
			}
		default:
			if strings.HasPrefix(a, "-") {
				return p, fmt.Errorf("unknown paper capture flag %q", a)
			}
			pos = append(pos, a)
		}
	}
	if len(pos) != 1 || strings.TrimSpace(pos[0]) != pos[0] || pos[0] == "" {
		return p, fmt.Errorf("paper capture needs exactly one canonical <source-url>")
	}
	p.sourceURL = pos[0]
	for _, f := range []struct{ name, value string }{
		{"--release-gate", p.releaseGateID}, {"--wave-revision", p.waveRevision},
		{"--candidate-id", p.candidateID}, {"--role", p.role},
		{"--deployment-digest", p.deploymentDigest},
	} {
		if strings.TrimSpace(f.value) == "" {
			return p, fmt.Errorf("%s is required", f.name)
		}
	}
	if p.role != "campaign" && p.role != "successor" {
		return p, fmt.Errorf("--role must be campaign or successor")
	}
	if len(p.deploymentDigest) != sha256.Size*2 {
		return p, fmt.Errorf("--deployment-digest must be a lowercase SHA-256 digest")
	}
	if _, err := hex.DecodeString(p.deploymentDigest); err != nil || strings.ToLower(p.deploymentDigest) != p.deploymentDigest {
		return p, fmt.Errorf("--deployment-digest must be a lowercase SHA-256 digest")
	}
	return p, nil
}

func renderPaperCaptureReaders(source apiclient.ReleasePaperSource, opt paperCaptureArgs) (map[string]paperCaptureReader, error) {
	docJSON, err := source.DocumentJSON(source.DocID)
	if err != nil {
		return nil, fmt.Errorf("build candidate document: %w", err)
	}
	var doc apiclient.Doc
	if err := json.Unmarshal(docJSON, &doc); err != nil {
		return nil, fmt.Errorf("decode candidate document: %w", err)
	}
	blocksRaw := doc.PaperBlocks()
	blocks, err := pdrender.Decode(blocksRaw)
	if err != nil {
		return nil, fmt.Errorf("decode candidate blocks: %w", err)
	}

	// CLI: the real one-shot pdrender path at the deterministic non-TTY profile.
	lipgloss.SetColorProfile(paperTermenvProfile(pdrender.NoColor))
	cliTheme := pdrender.DarkTheme()
	cliRaw := pdrender.DefaultRegistry(cliTheme).RenderDoc(blocks, pdrender.RenderCtx{
		Width: opt.width, Theme: cliTheme, Profile: pdrender.NoColor,
	}) + "\n"
	cliRaw = paperCaptureWithTitle(source.Title, cliRaw)

	// Task board: the exported production FramePaper renderer, not a capture-only
	// marker or approximation. An immutable candidate has no mutable task rail.
	ps := taskboard.PaperState{Slug: source.DocID, Title: source.Title, Rev: source.CandidateID, BlocksRaw: source.Blocks}
	lipgloss.SetColorProfile(paperTermenvProfile(pdrender.ANSI256))
	taskLines, _ := taskboard.RenderPaperFrame(ps, nil, nil, 0, opt.width, captureEpoch)
	taskRaw := strings.Join(taskLines, "\n") + "\n"

	// TUI: the same pdrender registry used by the interactive Paper pane, with
	// its production max-width reading column and centering geometry.
	lipgloss.SetColorProfile(paperTermenvProfile(pdrender.ANSI256))
	tuiWidth := opt.width
	if tuiWidth > paperTUIMaxWidth {
		tuiWidth = paperTUIMaxWidth
	}
	tuiTheme := pdrender.DarkTheme()
	tuiBody := pdrender.DefaultRegistry(tuiTheme).RenderDoc(blocks, pdrender.RenderCtx{
		Width: tuiWidth, Theme: tuiTheme, Profile: pdrender.ANSI256,
	})
	leftPad := (opt.width - tuiWidth) / 2
	if leftPad > 0 {
		pad := strings.Repeat(" ", leftPad)
		parts := strings.Split(tuiBody, "\n")
		for i := range parts {
			parts[i] = pad + parts[i]
		}
		tuiBody = strings.Join(parts, "\n")
	}
	tuiRaw := tuiBody + "\n"
	tuiRaw = paperCaptureWithTitle(source.Title, tuiRaw)

	binaryDigest, err := captureBinaryDigest()
	if err != nil {
		return nil, fmt.Errorf("identify capture binary: %w", err)
	}
	parserDigest := digestString(paperCaptureParserIdentity + "\n" + binaryDigest)
	sourceSum := sha256.Sum256(source.Raw)
	sourceDigest := hex.EncodeToString(sourceSum[:])
	argv := []string{"bp", "paper", "capture", opt.sourceURL,
		"--release-gate", opt.releaseGateID, "--wave-revision", opt.waveRevision,
		"--candidate-id", opt.candidateID, "--role", opt.role,
		"--deployment-digest", opt.deploymentDigest, "--width", fmt.Sprint(opt.width), "-o", "json"}
	base := paperCaptureProvenance{Argv: argv, BinaryDigest: binaryDigest,
		DeploymentDigest: opt.deploymentDigest, ParserDigest: parserDigest,
		SourceDigest: sourceDigest, Status: 0}
	reader := func(raw, geometry, theme, profile string) (paperCaptureReader, error) {
		if raw == "" || !utf8.ValidString(raw) {
			return paperCaptureReader{}, fmt.Errorf("reader emitted empty or invalid UTF-8")
		}
		p := base
		p.Geometry, p.Theme, p.Profile = geometry, theme, profile
		return paperCaptureReader{RawUTF8: raw, Provenance: p}, nil
	}
	cliReader, err := reader(cliRaw, fmt.Sprintf("%dxunbounded", opt.width), "evergreen-dark", "none")
	if err != nil {
		return nil, err
	}
	taskReader, err := reader(taskRaw, fmt.Sprintf("%dxunbounded", opt.width), "task-board-dark", "ansi256")
	if err != nil {
		return nil, err
	}
	tuiReader, err := reader(tuiRaw, fmt.Sprintf("%dxunbounded;measure=%d", opt.width, tuiWidth), "evergreen-dark", "ansi256")
	if err != nil {
		return nil, err
	}
	return map[string]paperCaptureReader{"cli": cliReader, "task_board": taskReader, "tui": tuiReader}, nil
}

func paperCaptureWithTitle(title, body string) string {
	title = strings.TrimSpace(title)
	if title == "" || strings.Contains(strings.ToLower(body), strings.ToLower(title)) {
		return body
	}
	return title + "\n\n" + body
}

var captureEpoch = func() time.Time { return time.Unix(0, 0).UTC() }()

func digestString(value string) string {
	sum := sha256.Sum256([]byte(value))
	return hex.EncodeToString(sum[:])
}

func captureBinaryDigest() (string, error) {
	path, err := os.Executable()
	if err != nil {
		return "", err
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func usagePaperCapture(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp paper capture <canonical-source-url> --release-gate <uuid> --wave-revision <uuid> --candidate-id <uuid> --role campaign|successor --deployment-digest <sha256> [--width 120] -o json")
	p("  fetch one immutable Paper candidate once and emit real CLI, task-board, and TUI reader bytes")
}
