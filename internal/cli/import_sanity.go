package cli

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

// A `sanity dataset export` tarball (task-936c12b4a6f29030). It unpacks to one
// directory holding data.ndjson, an optional assets.json, and the asset files
// under images/ and files/. In data.ndjson an asset value is
// {"_sanityAsset": "image@file://./images/<sha>-<w>x<h>.<ext>"} in place of
// Sanity's {"asset": {"_ref": "image-<sha>-<w>x<h>-<ext>"}}; either shape may
// appear. `bp import <export.tar.gz>` uploads each asset file once as Barkpark
// media and rewrites every such value to {"asset": {"_type": "reference",
// "_ref": "<Barkpark asset id>"}}.

// sanityAssetsSuffix names the file beside the tarball that records which
// Sanity asset became which Barkpark asset, per target scope, so a re-run or a
// --from-line resume uploads nothing twice.
const sanityAssetsSuffix = ".assets.json"

// sanityPending prefixes the placeholder a rewritten value carries until its
// asset is uploaded. Uploads wait until the import has passed its refusal and
// confirmation checks, so a refused import uploads nothing.
const sanityPending = "bp-sanity-asset:"

// sanityAssetTypes are Sanity's own asset documents. Their files become
// Barkpark media, so the documents themselves are not imported.
var sanityAssetTypes = map[string]bool{"sanity.imageAsset": true, "sanity.fileAsset": true}

var (
	sanityImageID = regexp.MustCompile(`^image-([0-9a-f]+)-(\d+x\d+)-([a-z0-9]+)$`)
	sanityFileID  = regexp.MustCompile(`^file-([0-9a-f]+)-([a-z0-9]+)$`)
)

// sanityImport is an unpacked export, scanned and rewritten with placeholders.
type sanityImport struct {
	tarball string
	dir     string // temp dir holding the unpacked export
	root    string // the directory inside dir that holds data.ndjson
	ndjson  string // the rewritten data.ndjson, the file the import reads
	names   map[string]string
	// assets are the Sanity asset ids the documents reference, sorted.
	assets []string
	refs   int // asset values rewritten
	// skipped counts the Sanity asset documents left out, by line.
	skipped int
	// ids maps a Sanity asset id to its Barkpark asset id once uploaded or
	// read from the sidecar for this scope.
	ids map[string]string
}

func importIsSanityTarball(p string) bool {
	l := strings.ToLower(p)
	return strings.HasSuffix(l, ".tar.gz") || strings.HasSuffix(l, ".tgz")
}

func (s *sanityImport) cleanup() { _ = os.RemoveAll(s.dir) }

// sanityPrepare unpacks the tarball, checks that every asset value has its
// file, and writes data.ndjson back out with each asset value rewritten to a
// placeholder ref and each Sanity asset document blanked (kept as an empty
// line, so line numbers and --from-line still match the export).
func sanityPrepare(tarball, scope string) (*sanityImport, error) {
	dir, err := os.MkdirTemp("", "bp-sanity-import-")
	if err != nil {
		return nil, err
	}
	s := &sanityImport{tarball: tarball, dir: dir, names: map[string]string{}, ids: map[string]string{}}
	if err := s.unpack(); err != nil {
		s.cleanup()
		return nil, err
	}
	if err := s.rewrite(); err != nil {
		s.cleanup()
		return nil, err
	}
	known, err := sanityReadSidecar(tarball)
	if err != nil {
		s.cleanup()
		return nil, err
	}
	for id, bp := range known[scope] {
		s.ids[id] = bp
	}
	return s, nil
}

// unpack extracts data.ndjson, assets.json and images/ + files/ entries. An
// entry with an absolute path or a `..` segment refuses the whole tarball.
func (s *sanityImport) unpack() error {
	f, err := os.Open(s.tarball)
	if err != nil {
		return err
	}
	defer f.Close()
	gz, err := gzip.NewReader(f)
	if err != nil {
		return fmt.Errorf("not a gzip tarball: %v", err)
	}
	tr := tar.NewReader(gz)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("unreadable tarball: %v", err)
		}
		name := strings.TrimPrefix(h.Name, "./")
		if path.IsAbs(name) || strings.Contains("/"+name+"/", "/../") {
			return fmt.Errorf("the tarball entry %q points outside the export", h.Name)
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		dst := filepath.Join(s.dir, filepath.FromSlash(name))
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		w, err := os.Create(dst)
		if err != nil {
			return err
		}
		if _, err := io.Copy(w, tr); err != nil {
			w.Close()
			return err
		}
		if err := w.Close(); err != nil {
			return err
		}
		if path.Base(name) == "data.ndjson" {
			if s.root != "" {
				return fmt.Errorf("the tarball holds more than one data.ndjson")
			}
			s.root = filepath.Dir(dst)
		}
	}
	if s.root == "" {
		return fmt.Errorf("the tarball holds no data.ndjson, so it is not a `sanity dataset export`")
	}
	if raw, err := os.ReadFile(filepath.Join(s.root, "assets.json")); err == nil {
		var meta map[string]struct {
			OriginalFilename string `json:"originalFilename"`
		}
		if json.Unmarshal(raw, &meta) == nil {
			for id, m := range meta {
				s.names[id] = m.OriginalFilename
			}
		}
	}
	return nil
}

// sanityAssetFile is the export-relative file a Sanity asset id names.
func sanityAssetFile(id string) (string, bool) {
	if m := sanityImageID.FindStringSubmatch(id); m != nil {
		return "images/" + m[1] + "-" + m[2] + "." + m[3], true
	}
	if m := sanityFileID.FindStringSubmatch(id); m != nil {
		return "files/" + m[1] + "." + m[2], true
	}
	return "", false
}

// sanityAssetID is the Sanity asset id for a `_sanityAsset` value
// ("image@file://./images/<sha>-<w>x<h>.<ext>"), the inverse of sanityAssetFile.
func sanityAssetID(v string) (string, error) {
	kind, loc, ok := strings.Cut(v, "@")
	if !ok || (kind != "image" && kind != "file") {
		return "", fmt.Errorf("unreadable _sanityAsset value %q", v)
	}
	rel, ok := strings.CutPrefix(loc, "file://./")
	if !ok {
		return "", fmt.Errorf("_sanityAsset %q is not a file in the export; re-run `sanity dataset export` with assets", v)
	}
	base := path.Base(rel)
	dot := strings.LastIndex(base, ".")
	if dot < 0 {
		return "", fmt.Errorf("unreadable _sanityAsset value %q", v)
	}
	id := kind + "-" + base[:dot] + "-" + base[dot+1:]
	if f, ok := sanityAssetFile(id); !ok || f != rel {
		return "", fmt.Errorf("unreadable _sanityAsset value %q", v)
	}
	return id, nil
}

// rewrite reads data.ndjson, swaps each asset value for a placeholder and
// writes the result beside it. A line with no asset value is copied byte for
// byte. Every referenced file must exist, or nothing is imported.
func (s *sanityImport) rewrite() error {
	in, err := os.Open(filepath.Join(s.root, "data.ndjson"))
	if err != nil {
		return err
	}
	defer in.Close()
	s.ndjson = filepath.Join(s.dir, "rewritten.ndjson")
	out, err := os.Create(s.ndjson)
	if err != nil {
		return err
	}
	defer out.Close()
	w := bufio.NewWriter(out)

	seen := map[string]bool{}
	var missing []string
	r := bufio.NewReader(in)
	line := 0
	for {
		raw, rerr := r.ReadBytes('\n')
		if rerr != nil && !errors.Is(rerr, io.EOF) {
			return rerr
		}
		if len(raw) > 0 {
			line++
			body := bytes.TrimSpace(raw)
			if len(body) > 0 && (bytes.Contains(body, []byte(`"_sanityAsset"`)) || bytes.Contains(body, []byte(`"sanity.`)) || bytes.Contains(body, []byte(`"_ref"`))) {
				dec := json.NewDecoder(bytes.NewReader(body))
				dec.UseNumber()
				var doc map[string]any
				if err := dec.Decode(&doc); err != nil {
					return fmt.Errorf("line %d is not a JSON object: %v", line, err)
				}
				if t, _ := doc["_type"].(string); sanityAssetTypes[t] {
					s.skipped++
					body = nil
				} else {
					var werr error
					changed := sanityWalk(doc, func(id string) string {
						if !seen[id] {
							seen[id] = true
							rel, _ := sanityAssetFile(id)
							if _, err := os.Stat(filepath.Join(s.root, filepath.FromSlash(rel))); err != nil {
								missing = append(missing, fmt.Sprintf("%s (line %d)", rel, line))
							}
							s.assets = append(s.assets, id)
						}
						s.refs++
						return sanityPending + id
					}, &werr)
					if werr != nil {
						return fmt.Errorf("line %d: %v", line, werr)
					}
					if changed {
						if body, err = json.Marshal(doc); err != nil {
							return fmt.Errorf("line %d: %v", line, err)
						}
					}
				}
			}
			if _, err := w.Write(body); err != nil {
				return err
			}
			if err := w.WriteByte('\n'); err != nil {
				return err
			}
		}
		if rerr != nil {
			break
		}
	}
	if len(missing) > 0 {
		return fmt.Errorf("%d asset file(s) the documents reference are not in the tarball: %s", len(missing), strings.Join(missing, ", "))
	}
	sort.Strings(s.assets)
	return w.Flush()
}

// sanityWalk rewrites every asset value under v in place and reports whether
// it changed anything. `{_sanityAsset: …}` loses that key and gains `asset`;
// `{asset: {_ref: "image-…"}}` gets a new `_ref`. A `_ref` that is not a
// Sanity asset id (a document reference) is left alone.
func sanityWalk(v any, resolve func(id string) string, werr *error) bool {
	changed := false
	switch t := v.(type) {
	case map[string]any:
		if sa, ok := t["_sanityAsset"].(string); ok {
			id, err := sanityAssetID(sa)
			if err != nil {
				*werr = err
				return false
			}
			delete(t, "_sanityAsset")
			t["asset"] = map[string]any{"_type": "reference", "_ref": resolve(id)}
			return true
		}
		rewrote := false
		if a, ok := t["asset"].(map[string]any); ok {
			if ref, ok := a["_ref"].(string); ok {
				if _, isAsset := sanityAssetFile(ref); isAsset {
					t["asset"] = map[string]any{"_type": "reference", "_ref": resolve(ref)}
					changed, rewrote = true, true
				}
			}
		}
		for k, c := range t {
			if k == "asset" && rewrote {
				continue
			}
			if sanityWalk(c, resolve, werr) {
				changed = true
			}
		}
	case []any:
		for _, c := range t {
			if sanityWalk(c, resolve, werr) {
				changed = true
			}
		}
	}
	return changed
}

// pending is how many referenced assets have no Barkpark id yet.
func (s *sanityImport) pending() int {
	n := 0
	for _, id := range s.assets {
		if s.ids[id] == "" {
			n++
		}
	}
	return n
}

// upload sends each asset that has no Barkpark id for this scope, recording
// each new id in the sidecar as soon as the server confirms it.
func (s *sanityImport) upload(out *writer, ctx manifest.Context, dataset, scope string) error {
	u := ctxScopedURL(ctx, "/v1/media/"+url.PathEscape(dataset)+"/upload")
	done := 0
	for _, id := range s.assets {
		if s.ids[id] != "" {
			continue
		}
		rel, _ := sanityAssetFile(id)
		bpID, err := s.uploadOne(u, ctx, id, filepath.Join(s.root, filepath.FromSlash(rel)))
		if err != nil {
			return fmt.Errorf("uploading %s: %v", rel, err)
		}
		s.ids[id] = bpID
		if err := sanityWriteSidecar(s.tarball, scope, s.ids); err != nil {
			return err
		}
		done++
		if !out.machineOut() && done%25 == 0 {
			out.errf("import: %d asset(s) uploaded", done)
		}
	}
	return nil
}

func (s *sanityImport) uploadOne(u string, ctx manifest.Context, id, file string) (string, error) {
	data, err := os.ReadFile(file)
	if err != nil {
		return "", err
	}
	name := s.names[id]
	if name == "" {
		name = filepath.Base(file)
	}
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	h := make(map[string][]string)
	h["Content-Disposition"] = []string{fmt.Sprintf(`form-data; name="file"; filename=%q`, name)}
	ct := mime.TypeByExtension(filepath.Ext(file))
	if ct == "" {
		ct = "application/octet-stream"
	}
	h["Content-Type"] = []string{ct}
	part, err := mw.CreatePart(h)
	if err != nil {
		return "", err
	}
	if _, err := part.Write(data); err != nil {
		return "", err
	}
	if err := mw.Close(); err != nil {
		return "", err
	}
	headers := ctxAuthHeaders(ctx)
	headers["Content-Type"] = mw.FormDataContentType()
	status, body, err := doRequest("POST", u, headers, buf.Bytes())
	if err != nil {
		return "", err
	}
	if status < 200 || status >= 300 {
		return "", fmt.Errorf("the server answered %d: %s", status, bytes.TrimSpace(body))
	}
	if err := builtinWriteReceiptErr("import asset upload", status, body); err != nil {
		return "", err
	}
	var receipt struct {
		Result struct {
			AssetDocID string `json:"assetDocId"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &receipt); err != nil || receipt.Result.AssetDocID == "" {
		return "", fmt.Errorf("the upload receipt names no assetDocId: %s", bytes.TrimSpace(body))
	}
	return strings.TrimPrefix(receipt.Result.AssetDocID, "drafts."), nil
}

// resolve swaps each row's placeholders for the uploaded Barkpark ids.
func (s *sanityImport) resolve(rows []*importRow) {
	pairs := make([]string, 0, 2*len(s.ids))
	for id, bp := range s.ids {
		pairs = append(pairs, `"`+sanityPending+id+`"`, strconvQuote(bp))
	}
	rep := strings.NewReplacer(pairs...)
	for _, r := range rows {
		for k, m := range r.mutations {
			if bytes.Contains(m, []byte(sanityPending)) {
				r.mutations[k] = []byte(rep.Replace(string(m)))
			}
		}
	}
}

func strconvQuote(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}

func sanityReadSidecar(tarball string) (map[string]map[string]string, error) {
	raw, err := os.ReadFile(tarball + sanityAssetsSuffix)
	if os.IsNotExist(err) {
		return map[string]map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	var m map[string]map[string]string
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil, fmt.Errorf("%s%s is unreadable: %v", tarball, sanityAssetsSuffix, err)
	}
	return m, nil
}

func sanityWriteSidecar(tarball, scope string, ids map[string]string) error {
	all, err := sanityReadSidecar(tarball)
	if err != nil {
		return err
	}
	all[scope] = ids
	raw, err := json.MarshalIndent(all, "", "  ")
	if err != nil {
		return err
	}
	tmp := tarball + sanityAssetsSuffix + ".tmp"
	if err := os.WriteFile(tmp, append(raw, '\n'), 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, tarball+sanityAssetsSuffix)
}

func (s *sanityImport) summary() map[string]any {
	return map[string]any{
		"assets": len(s.assets), "refs": s.refs, "to_upload": s.pending(),
		"asset_documents_skipped": s.skipped, "assets_file": s.tarball + sanityAssetsSuffix,
	}
}
