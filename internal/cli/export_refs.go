package cli

// export_refs.go is `bp export --follow-refs` and the media filter of a
// partial export (task-c3df8afd76b35c2f).
//
// The Pensum box copies on 2026-11-06 and 2026-11-18 built their subset of
// gyl's production offline with pensum_set.py: seed documents chosen by type
// and id, then every document their references reach, then the media files
// those documents use. This file does the same inside bp export, with the
// same three kinds of reference:
//
//   - a `_ref` string anywhere in the document, with any drafts. prefix removed
//   - an `asset-<uuid>` inside any string
//   - a `/media/files/<path>` URL inside any string, which names the asset
//     whose file has that path in the dataset's media list
//
// A document is kept by its published id, so its draft and published rows go
// together. A reference to an id the dataset does not hold is dangling and
// reported.

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"regexp"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

var (
	refMediaPathRE = regexp.MustCompile(`/media/files/([^\s"'?#)]+)`)
	refAssetIDRE   = regexp.MustCompile(`\basset-([0-9a-f-]{36})\b`)
)

// docRefs is what one exported document points at.
type docRefs struct {
	ids   []string // published ids, from _ref values and asset-<uuid> strings
	paths []string // media file paths, from /media/files/<path> URLs
}

// exportDocHead reads the id and type of one exported line and the
// references in it. The document's own top-level _id is not a reference.
func exportDocHead(line string) (id, typ string, refs docRefs, err error) {
	var doc map[string]any
	if err := json.Unmarshal([]byte(line), &doc); err != nil {
		return "", "", refs, err
	}
	id, _ = doc["_id"].(string)
	typ, _ = doc["_type"].(string)
	for k, v := range doc {
		if k != "_id" {
			collectRefs(v, &refs)
		}
	}
	return id, typ, refs, nil
}

func collectRefs(v any, refs *docRefs) {
	switch x := v.(type) {
	case map[string]any:
		if r, ok := x["_ref"].(string); ok {
			refs.ids = append(refs.ids, strings.TrimPrefix(r, "drafts."))
		}
		for _, child := range x {
			collectRefs(child, refs)
		}
	case []any:
		for _, child := range x {
			collectRefs(child, refs)
		}
	case string:
		if strings.Contains(x, "/media/files/") {
			for _, m := range refMediaPathRE.FindAllStringSubmatch(x, -1) {
				refs.paths = append(refs.paths, m[1])
			}
		}
		if strings.Contains(x, "asset-") {
			for _, m := range refAssetIDRE.FindAllStringSubmatch(x, -1) {
				refs.ids = append(refs.ids, "asset-"+m[1])
			}
		}
	}
}

// exportTypeMatches reports whether typ is one of types. A name ending in *
// matches every type that starts with the rest: pensum* matches pensumBook.
func exportTypeMatches(types []string, typ string) bool {
	for _, t := range types {
		if p, ok := strings.CutSuffix(t, "*"); ok {
			if strings.HasPrefix(typ, p) {
				return true
			}
		} else if t == typ {
			return true
		}
	}
	return false
}

// mediaWanted is the set of media files a partial export writes: the assets
// whose document it exported or that an exported document references.
type mediaWanted struct {
	ids   map[string]bool // document ids, asset-<uuid>
	paths map[string]bool // media file paths
}

func newMediaWanted() *mediaWanted {
	return &mediaWanted{ids: map[string]bool{}, paths: map[string]bool{}}
}

// add records one exported document and what it references.
func (w *mediaWanted) add(id string, refs docRefs) {
	w.ids[strings.TrimPrefix(id, "drafts.")] = true
	for _, r := range refs.ids {
		w.ids[r] = true
	}
	for _, p := range refs.paths {
		w.paths[p] = true
	}
}

func (w *mediaWanted) wants(a mediaCopyAsset) bool {
	return w.ids["asset-"+a.ID] || (a.Path != "" && w.paths[a.Path])
}

// exportSubset is the plan of one --follow-refs or --id export.
type exportSubset struct {
	types []string // seed types; a trailing * is a prefix
	ids   []string // seed document ids, published or drafts.
	depth int      // reference hops to follow; -1 follows until nothing new turns up
}

// exportSubsetResult is what exportSubset.run wrote.
type exportSubsetResult struct {
	docs      int
	seeds     int      // published ids chosen by type or id
	reached   int      // published ids added by following references
	types     []string // types written, in the order first seen
	dangling  []string // referenced ids the dataset does not hold
	missingID []string // --id values the dataset does not hold
	media     *mediaWanted
}

// run streams the whole dataset once into a temporary file, picks the seed
// documents, follows their references, and then writes the kept lines in the
// order the export gave them. pathToAsset maps a media file path to its
// asset-<uuid> document id; it may be nil when the dataset has no media.
func (s exportSubset) run(ctx context.Context, client *apiclient.Client, opts apiclient.ExportOpts, tmpDir string,
	pathToAsset map[string]string, writeLine func(string) error) (exportSubsetResult, error) {
	res := exportSubsetResult{media: newMediaWanted()}
	tmp, err := os.CreateTemp(tmpDir, "bp-export-all-*.ndjson")
	if err != nil {
		return res, err
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()

	// refsOf holds, per published id, every id its rows reference.
	refsOf := map[string][]string{}
	present := map[string]bool{}
	keep := map[string]bool{}
	var queue []string
	buf := bufio.NewWriter(tmp)
	opts.Type = ""
	err = client.Export(ctx, opts, func(line string) error {
		id, typ, refs, err := exportDocHead(line)
		if err != nil {
			return fmt.Errorf("unreadable export line: %v", err)
		}
		base := strings.TrimPrefix(id, "drafts.")
		present[base] = true
		for _, p := range refs.paths {
			if a, ok := pathToAsset[p]; ok {
				refs.ids = append(refs.ids, a)
			}
		}
		refsOf[base] = append(refsOf[base], refs.ids...)
		if !keep[base] && (exportTypeMatches(s.types, typ) || containsString(s.ids, id) || containsString(s.ids, base)) {
			keep[base] = true
			queue = append(queue, base)
		}
		_, err = buf.WriteString(line + "\n")
		return err
	})
	if err != nil {
		return res, err
	}
	if err := buf.Flush(); err != nil {
		return res, err
	}
	for _, id := range s.ids {
		if !present[strings.TrimPrefix(id, "drafts.")] {
			res.missingID = append(res.missingID, id)
		}
	}
	res.seeds = len(queue)

	// Breadth first, one hop per level, so --follow-refs=N stops after N hops.
	dangling := map[string]bool{}
	for hop := 0; len(queue) > 0 && (s.depth < 0 || hop < s.depth); hop++ {
		var next []string
		for _, id := range queue {
			for _, r := range refsOf[id] {
				if keep[r] {
					continue
				}
				if !present[r] {
					dangling[r] = true
					continue
				}
				keep[r] = true
				next = append(next, r)
			}
		}
		res.reached += len(next)
		queue = next
	}
	for r := range dangling {
		res.dangling = append(res.dangling, r)
	}
	sort.Strings(res.dangling)

	if _, err := tmp.Seek(0, io.SeekStart); err != nil {
		return res, err
	}
	r := bufio.NewReader(tmp)
	seenType := map[string]bool{}
	for {
		raw, rerr := r.ReadString('\n')
		if rerr != nil && !errors.Is(rerr, io.EOF) {
			return res, rerr
		}
		if line := strings.TrimRight(raw, "\n"); line != "" {
			id, typ, refs, err := exportDocHead(line)
			if err != nil {
				return res, err
			}
			if keep[strings.TrimPrefix(id, "drafts.")] {
				if err := writeLine(line); err != nil {
					return res, err
				}
				res.docs++
				res.media.add(id, refs)
				if !seenType[typ] {
					seenType[typ] = true
					res.types = append(res.types, typ)
				}
			}
		}
		if rerr != nil {
			break
		}
	}
	return res, nil
}
