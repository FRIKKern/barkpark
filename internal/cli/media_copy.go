package cli

// media_copy.go is `bp export --media <dir>` and `bp import --media <dir>`
// (task-fa5aedea4a584d34): copy one dataset's media files to another instance
// over the API and keep each asset id, so content that references
// `asset-<id>` still resolves after the copy.
//
// Export lists the dataset's media (GET /v1/media/:dataset), reads each file
// from its scoped delivery route with fetchOneBlob, checks its SHA-1, and
// writes <dir>/files/<id> plus <dir>/media.json. A file already in the
// directory with the right SHA-1 is not read again, so a stopped export is
// resumed by running it again.
//
// Import uploads each file with `mediaFileId` set to its id. The server keeps
// the id, skips byte dedupe, and answers a re-run with the same file, so a
// stopped import is resumed by running it again. The mediaAsset rows of the
// NDJSON then overwrite the asset documents the uploads created, with
// fileInfo.path and fileInfo.url taken from the target, because the target
// stores the bytes under its own path.

import (
	"bytes"
	"crypto/sha1"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"mime/multipart"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/manifest"
)

const mediaCopyManifest = "media.json"

// mediaCopyAsset is one file in media.json.
type mediaCopyAsset struct {
	ID           string `json:"id"`
	SHA1         string `json:"sha1"`
	Size         int64  `json:"size"`
	OriginalName string `json:"originalName"`
	MimeType     string `json:"mimeType"`
	SourceID     string `json:"sourceId,omitempty"`
	Path         string `json:"path"`
}

type mediaCopyFile struct {
	Scope  string           `json:"scope"`
	Assets []mediaCopyAsset `json:"assets"`
}

// exportMedia writes every media file of the dataset to dir.
func exportMedia(out *writer, ctx manifest.Context, dataset, dir string) int {
	if err := os.MkdirAll(filepath.Join(dir, "files"), 0o755); err != nil {
		return useError(out, "failed", fmt.Sprintf("export --media: %v", err), exitGeneric)
	}
	var assets []mediaCopyAsset
	for offset := 0; ; {
		u := ctxScopedURL(ctx, "/v1/media/"+url.PathEscape(dataset)+"?limit=500&offset="+strconv.Itoa(offset))
		status, body, err := doRequest("GET", u, ctxAuthHeaders(ctx), nil)
		if err != nil {
			return useError(out, "request_failed", fmt.Sprintf("export --media: listing media: %v", err), exitGeneric)
		}
		if status < 200 || status >= 300 {
			ae := classifyError(status, body)
			renderError(out, ae)
			return ae.exit
		}
		var page struct {
			Result struct {
				Assets  []mediaCopyAsset `json:"assets"`
				HasMore bool             `json:"hasMore"`
			} `json:"result"`
		}
		if err := json.Unmarshal(body, &page); err != nil {
			return useError(out, "unreadable_response", fmt.Sprintf("export --media: the media list did not parse: %v", err), exitGeneric)
		}
		assets = append(assets, page.Result.Assets...)
		if !page.Result.HasMore || len(page.Result.Assets) == 0 {
			break
		}
		offset += len(page.Result.Assets)
	}

	// The files are read from the same scope the list came from, which
	// ctxScopedURL defaults to default/default.
	ws, project := ctx.Workspace, ctx.Project
	if ws == "" {
		ws = "default"
	}
	if project == "" {
		project = "default"
	}
	client := newTransferClient()
	pacer := newMediaPacer(defaultMediaRatePerMinute)
	fetched := 0
	for k, a := range assets {
		if !safeBlobPath(a.Path) || strings.ContainsAny(a.ID, `/\`) || a.ID == "" {
			return useError(out, "unreadable_response", fmt.Sprintf("export --media: asset %q has an unsafe id or path %q", a.ID, a.Path), exitGeneric)
		}
		dest := filepath.Join(dir, "files", a.ID)
		if sum, err := mediaFileSHA1(dest); err == nil && sum == a.SHA1 {
			continue
		}
		ref := mediaBlobRef{path: a.Path, size: a.Size, sizeKnown: true, project: project}
		if _, _, err, code := fetchOneBlob(client, pacer, strings.TrimRight(ctx.Server, "/"), ctx.Token, ws, ref, dest); err != nil {
			return useError(out, "request_failed", fmt.Sprintf("export --media: %s (%s): %v. Run the export again to resume.", a.ID, a.Path, err), code)
		}
		if a.SHA1 != "" {
			if sum, err := mediaFileSHA1(dest); err != nil || sum != a.SHA1 {
				_ = os.Remove(dest)
				return useError(out, "validation_failed", fmt.Sprintf("export --media: %s: the bytes read do not match sha1 %s", a.ID, a.SHA1), exitGeneric)
			}
		}
		fetched++
		if !out.machineOut() && fetched%25 == 0 {
			out.errf("export: %d of %d media file(s) read", k+1, len(assets))
		}
	}
	manifestBody, _ := json.MarshalIndent(mediaCopyFile{Scope: exportScope(ctx), Assets: assets}, "", "  ")
	if err := os.WriteFile(filepath.Join(dir, mediaCopyManifest), append(manifestBody, '\n'), 0o644); err != nil {
		return useError(out, "failed", fmt.Sprintf("export --media: %v", err), exitGeneric)
	}
	out.errf("exported %d media file(s) to %s (%d read now, %d already there)", len(assets), dir, fetched, len(assets)-fetched)
	return exitOK
}

func mediaFileSHA1(path string) (string, error) {
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	h := sha1.New()
	if _, err := io.Copy(h, f); err != nil {
		return "", err
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

// importMedia is the import half: the files in dir and, once uploaded, the
// path each one has on the target.
type importMedia struct {
	dir    string
	assets []mediaCopyAsset
	ids    map[string]bool
	paths  map[string]string // id -> target path, filled by upload
}

func readImportMedia(dir string) (*importMedia, error) {
	raw, err := os.ReadFile(filepath.Join(dir, mediaCopyManifest))
	if err != nil {
		return nil, fmt.Errorf("cannot read %s: %v (write it with `bp export --media %s`)", filepath.Join(dir, mediaCopyManifest), err, dir)
	}
	var mf mediaCopyFile
	if err := json.Unmarshal(raw, &mf); err != nil {
		return nil, fmt.Errorf("%s does not parse: %v", filepath.Join(dir, mediaCopyManifest), err)
	}
	m := &importMedia{dir: dir, assets: mf.Assets, ids: map[string]bool{}, paths: map[string]string{}}
	for _, a := range mf.Assets {
		if a.ID == "" || strings.ContainsAny(a.ID, `/\`) {
			return nil, fmt.Errorf("%s lists an asset with an unsafe id %q", mediaCopyManifest, a.ID)
		}
		if _, err := os.Stat(filepath.Join(dir, "files", a.ID)); err != nil {
			return nil, fmt.Errorf("the file for asset %s is missing: %v", a.ID, err)
		}
		m.ids[a.ID] = true
	}
	return m, nil
}

// owns reports whether r is the asset document of a file this import uploads.
// The upload creates that document, so it is overwritten, not a collision.
func (m *importMedia) owns(r *importRow) bool {
	return r.Type == "mediaAsset" && m.ids[strings.TrimPrefix(strings.TrimPrefix(r.ID, "drafts."), "asset-")]
}

// upload sends every file with its id and checks the id and SHA-1 the server
// answers with.
func (m *importMedia) upload(out *writer, ctx manifest.Context, dataset string) error {
	u := ctxScopedURL(ctx, "/v1/media/"+url.PathEscape(dataset)+"/upload")
	for k, a := range m.assets {
		path, err := m.uploadOne(u, ctx, a)
		if err != nil {
			return fmt.Errorf("uploading media %s: %v", a.ID, err)
		}
		m.paths[a.ID] = path
		if !out.machineOut() && (k+1)%25 == 0 {
			out.errf("import: %d of %d media file(s) uploaded", k+1, len(m.assets))
		}
	}
	return nil
}

func (m *importMedia) uploadOne(u string, ctx manifest.Context, a mediaCopyAsset) (string, error) {
	data, err := os.ReadFile(filepath.Join(m.dir, "files", a.ID))
	if err != nil {
		return "", err
	}
	name := a.OriginalName
	if name == "" {
		name = a.ID
	}
	var buf bytes.Buffer
	mw := multipart.NewWriter(&buf)
	if err := mw.WriteField("mediaFileId", a.ID); err != nil {
		return "", err
	}
	if a.SourceID != "" {
		if err := mw.WriteField("sourceId", a.SourceID); err != nil {
			return "", err
		}
	}
	ct := a.MimeType
	if ct == "" {
		ct = mime.TypeByExtension(filepath.Ext(name))
	}
	if ct == "" {
		ct = "application/octet-stream"
	}
	h := map[string][]string{
		"Content-Disposition": {fmt.Sprintf(`form-data; name="file"; filename=%q`, name)},
		"Content-Type":        {ct},
	}
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
	if status == 409 {
		// A re-run in the same dataset answers 2xx, so a 409 means another
		// dataset on this instance already holds the id.
		ae := classifyError(status, body)
		return "", fmt.Errorf("the server answered 409: %s. Media file ids are unique per instance, so this instance already holds %s in another dataset. Import into a different instance; see docs/setup/SELF-HOST-MOVE.md#copy-one-dataset-over-the-api", ae.errorMessage(), a.ID)
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, body)
		return "", fmt.Errorf("the server answered %d: %s", status, ae.errorMessage())
	}
	if err := builtinWriteReceiptErr("import media upload", status, body); err != nil {
		return "", err
	}
	var receipt struct {
		Result struct {
			ID   string `json:"id"`
			SHA1 string `json:"sha1"`
			Path string `json:"path"`
		} `json:"result"`
	}
	if err := json.Unmarshal(body, &receipt); err != nil {
		return "", fmt.Errorf("the upload receipt did not parse: %v", err)
	}
	if receipt.Result.ID != a.ID {
		return "", fmt.Errorf("the server stored it as %q, so this server does not keep asset ids; upgrade it first", receipt.Result.ID)
	}
	if a.SHA1 != "" && receipt.Result.SHA1 != a.SHA1 {
		return "", fmt.Errorf("the server holds sha1 %s, the export has %s", receipt.Result.SHA1, a.SHA1)
	}
	return receipt.Result.Path, nil
}

// resolve points each uploaded asset document's fileInfo at the target's copy
// of the file. Every other field is sent as exported.
func (m *importMedia) resolve(rows []*importRow) error {
	const prefix = `{"createOrReplace":`
	for _, r := range rows {
		if !m.owns(r) {
			continue
		}
		path, ok := m.paths[strings.TrimPrefix(strings.TrimPrefix(r.ID, "drafts."), "asset-")]
		if !ok || path == "" {
			continue
		}
		raw := r.mutations[0]
		var doc map[string]json.RawMessage
		if err := json.Unmarshal(raw[len(prefix):len(raw)-1], &doc); err != nil {
			return fmt.Errorf("line %d: %v", r.Line, err)
		}
		info := map[string]any{}
		if fi, ok := doc["fileInfo"]; ok {
			_ = json.Unmarshal(fi, &info)
		}
		info["path"] = path
		info["url"] = "/media/files/" + path
		fi, err := json.Marshal(info)
		if err != nil {
			return err
		}
		doc["fileInfo"] = fi
		body, err := json.Marshal(doc)
		if err != nil {
			return err
		}
		r.mutations[0] = importJoin(prefix, body, `}`)
	}
	return nil
}
