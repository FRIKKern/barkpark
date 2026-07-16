// Command seed derives one Barkpark `command` document payload per
// scaffy/commands/*.scaffy corpus file (scaffy epic, W4 slice 4; charter
// D46/D47).
//
// It is a payload EMITTER, not an uploader: the seed loop itself is two bp
// verbs per payload (create-or-replace + publish) documented in README.md
// alongside this file. Payloads are derived artifacts — the .scaffy files
// are the truth — so the out dir is never committed.
//
// Per file it:
//  1. scaffy.ValidateFile — ANY finding refuses the whole run (exit 1);
//     nothing invalid is ever seeded.
//  2. Derives the flat document fields:
//     _id         <domain>--<concept>--<variant>   (D46: concept alone is
//     NON-unique — add-docs-card and remove-docs-card
//     share concept "docs-card")
//     title       COMMAND header value
//     description DESCRIPTION header value
//     concept / variant / domain / direction  from the header
//     tags        TAGS list re-split into weighted entries with DISTINCT
//     descending strengths 90, 80, 70, … (publish-wall law:
//     strengths must be distinct; rationale is honest — it
//     derives from header order, nothing deeper)
//     source      the RAW FILE BYTES verbatim, never trimmed or decomposed
//  3. Writes <out>/<_id>.json and prints an audit line with the sha256 of
//     source, so the post-seed parity check (server sha256 == repo sha256)
//     has a local anchor.
//
// Usage:
//
//	go run ./scaffy/seed [--commands scaffy/commands] [--out scaffy/seed/out]
package main

import (
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/scaffy"
)

// payload is one flat `command` document body for
// `bp doc create-or-replace command --file <payload>` — the CLI wraps it
// under a createOrReplace mutation; the type comes from the verb argument.
type payload struct {
	ID          string        `json:"_id"`
	Title       string        `json:"title"`
	Description string        `json:"description"`
	Concept     string        `json:"concept"`
	Variant     string        `json:"variant"`
	Domain      string        `json:"domain"`
	Direction   string        `json:"direction"`
	Tags        []weightedTag `json:"tags"`
	Source      string        `json:"source"`
}

// weightedTag is one entry of the weighted-tags composite the publish wall
// (E3 tag-registry gate) validates: every tag name must resolve to a
// PUBLISHED type:tag doc, and strengths must be distinct.
type weightedTag struct {
	Tag       string `json:"tag"`
	Strength  int    `json:"strength"`
	Rationale string `json:"rationale"`
}

func main() {
	commandsDir := flag.String("commands", "scaffy/commands", "directory of .scaffy corpus files")
	outDir := flag.String("out", "scaffy/seed/out", "directory to write one <_id>.json payload per command (derived; never committed)")
	flag.Parse()

	if err := run(*commandsDir, *outDir); err != nil {
		fmt.Fprintf(os.Stderr, "seed: %v\n", err)
		os.Exit(1)
	}
}

func run(commandsDir, outDir string) error {
	files, err := filepath.Glob(filepath.Join(commandsDir, "*.scaffy"))
	if err != nil {
		return err
	}
	if len(files) == 0 {
		return fmt.Errorf("no .scaffy files under %s", commandsDir)
	}
	sort.Strings(files)

	// Validate the ENTIRE corpus before emitting anything: a single finding
	// anywhere refuses the whole run, so a partial seed can never happen.
	invalid := false
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		if findings := scaffy.ValidateFile(f, src); len(findings) > 0 {
			invalid = true
			for _, fd := range findings {
				fmt.Fprintf(os.Stderr, "%s\n", fd)
			}
		}
	}
	if invalid {
		return fmt.Errorf("validation findings — refusing to seed")
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return err
	}

	seen := map[string]string{} // _id -> source file (D46 uniqueness tripwire)
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			return err
		}
		p, err := derive(f, src)
		if err != nil {
			return err
		}
		if prev, dup := seen[p.ID]; dup {
			return fmt.Errorf("%s: derived _id %q collides with %s — D46 ids must be unique", f, p.ID, prev)
		}
		seen[p.ID] = f

		out := filepath.Join(outDir, p.ID+".json")
		body, err := json.MarshalIndent(p, "", "  ")
		if err != nil {
			return err
		}
		if err := os.WriteFile(out, append(body, '\n'), 0o644); err != nil {
			return err
		}
		fmt.Printf("ok  %-42s tags=%d  sha256(source)=%x  <- %s\n",
			p.ID, len(p.Tags), sha256.Sum256(src), f)
	}
	fmt.Printf("emitted %d payloads to %s\n", len(files), outDir)
	return nil
}

// derive maps one validated .scaffy source to its document payload. Every
// header field the document model needs must be present — a hole is an
// error, never a silently-empty field.
func derive(file string, src []byte) (*payload, error) {
	cmd, findings := scaffy.Parse(file, src)
	if len(findings) > 0 {
		// Unreachable after ValidateFile, but fail closed anyway.
		return nil, fmt.Errorf("%s: parse findings after validation: %s", file, findings[0])
	}

	get := func(name string, hf interface{ value() (string, bool) }) (string, error) {
		v, ok := hf.value()
		if !ok || strings.TrimSpace(v) == "" {
			return "", fmt.Errorf("%s: header %s is missing or empty", file, name)
		}
		return strings.TrimSpace(v), nil
	}

	h := cmd.Header
	title, err := get("COMMAND", opt{h.Command})
	if err != nil {
		return nil, err
	}
	description, err := get("DESCRIPTION", opt{h.Description})
	if err != nil {
		return nil, err
	}
	domain, err := get("DOMAIN", opt{h.Domain})
	if err != nil {
		return nil, err
	}
	concept, err := get("CONCEPT", opt{h.Concept})
	if err != nil {
		return nil, err
	}
	variant, err := get("VARIANT", opt{h.Variant})
	if err != nil {
		return nil, err
	}
	tagsRaw, err := get("TAGS", opt{h.Tags})
	if err != nil {
		return nil, err
	}
	direction := cmd.Direction()
	if direction == "" {
		return nil, fmt.Errorf("%s: DIRECTION is missing or invalid", file)
	}

	tags, err := weightedTags(file, tagsRaw)
	if err != nil {
		return nil, err
	}

	return &payload{
		ID:          domain + "--" + concept + "--" + variant,
		Title:       title,
		Description: description,
		Concept:     concept,
		Variant:     variant,
		Domain:      domain,
		Direction:   direction,
		Tags:        tags,
		Source:      string(src),
	}, nil
}

// opt adapts a *scaffy.HeaderField to the small presence interface derive
// uses, so missing headers (nil) read uniformly.
type opt struct{ f *scaffy.HeaderField }

func (o opt) value() (string, bool) {
	if o.f == nil {
		return "", false
	}
	return o.f.Value, true
}

// weightedTags re-splits the parsed TAGS value (the parser joins the quoted
// list with ", ") into the weighted composite: distinct descending strengths
// from 90 in steps of 10 (90, 80, 70, …), honest positional rationales.
func weightedTags(file, raw string) ([]weightedTag, error) {
	parts := strings.Split(raw, ",")
	out := make([]weightedTag, 0, len(parts))
	seen := map[string]bool{}
	for i, p := range parts {
		name := strings.TrimSpace(p)
		if name == "" {
			return nil, fmt.Errorf("%s: TAGS entry %d is empty", file, i+1)
		}
		if seen[name] {
			return nil, fmt.Errorf("%s: TAGS entry %q repeats — weighted strengths must be distinct per tag", file, name)
		}
		seen[name] = true
		strength := 90 - 10*i
		if strength <= 0 {
			return nil, fmt.Errorf("%s: more than 9 TAGS entries — descending 90,80,… strengths exhausted", file)
		}
		out = append(out, weightedTag{
			Tag:       name,
			Strength:  strength,
			Rationale: fmt.Sprintf("TAGS position %d in the .scaffy header; strength mirrors header order.", i+1),
		})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("%s: TAGS produced no entries", file)
	}
	return out, nil
}
