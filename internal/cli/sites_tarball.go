package cli

// sites_tarball.go is the P7 "heroku moment" half of `bp deploy`: a streaming
// tar.gz of the project directory, shipped to the control plane's artifact
// upload route. The Goal is the canonical CLI flow:
//
//     cd ~/my-next-app && bp deploy --site demo
//
// produces a working uploaded tarball, the builder picks it up, the runtime
// deploys it — no `--artifact-url` flag needed.
//
// The streaming model is deliberate: we write through an io.Pipe so the tar
// archive and the gzip wrapper run in a goroutine while the HTTP upload reads
// from the other end. A 100 MB project never sits in RAM as one slice, and the
// upload starts as soon as the first chunk lands.

import (
	"archive/tar"
	"bufio"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io"
	"os"
	"path"
	"path/filepath"
	"strings"
)

// defaultTarballIgnores are the build artifacts / VCS noise the tar archive
// silently skips when no .gitignore exists. Mirrors the Vercel/Heroku
// "obvious junk" list: node_modules and lock-derived build outputs blow up the
// tarball without earning their bytes, and .git is its own kind of payload.
var defaultTarballIgnores = []string{
	"node_modules",
	".next",
	".nuxt",
	".svelte-kit",
	".astro",
	".turbo",
	".cache",
	"dist",
	"build",
	"out",
	".git",
	".DS_Store",
	"_build",
	"deps",
	".elixir_ls",
	".idea",
	".vscode",
	"coverage",
	"target",
	// The dotenv secret family. isIgnored matches exact basenames/segments (no
	// glob), so create-next-app's `.env*.local` .gitignore line never reaches
	// here — we enumerate every conventional dotenv file by name instead. These
	// are appended on every deploy (loadGitignore always layers the defaults),
	// so a secret-bearing .env at the project root can't be packed and uploaded
	// regardless of what the project's own .gitignore lists.
	".env",
	".env.local",
	".env.production",
	".env.development",
	".env.test",
	".env.production.local",
	".env.development.local",
	".env.test.local",
}

// prebuiltTarballIgnores is the ignore list for `bp cloud site deploy --prebuilt
// <dir>` — and it is EXPLICIT on purpose (charter D93). The prebuilt payload IS
// the build output, so the project defaults above are exactly wrong here: they
// carry `dist`, `build`, `out`, `.next`, `.astro` and `_build`, isIgnored matches
// ANY path segment, and a real Astro `dist/` packs down to a hollow shell that
// uploads, deploys and 404s.
//
// `tarballOptions.Ignores` is NIL-SENSITIVE IN BOTH DIRECTIONS and neither
// default is safe for this lane: nil falls through to loadGitignore + the
// payload-deleting defaults, while an empty slice ignores NOTHING — including a
// `.env` a framework wrote next to the built assets. So this list is neither: it
// keeps the dotenv family (a secret that must never leave the laptop) plus the
// two things that are never build output, and nothing else.
var prebuiltTarballIgnores = []string{
	".git",
	".DS_Store",
	".env",
	".env.local",
	".env.production",
	".env.development",
	".env.test",
	".env.production.local",
	".env.development.local",
	".env.test.local",
}

// prebuiltMaxWireBytes is the client-side cap on a prebuilt artifact, expressed
// in the SERVER's units: WIRE bytes (the gzip'd bytes that cross the socket),
// not the uncompressed payload the project-tarball cap counts. The box's
// Plug.Parsers length is 100 MB of body, and the two units are ~960x apart for
// text — so a cap stated in uncompressed bytes never fires before the server's
// does. A built `dist/` is kilobytes; anything near this number is a mistake we
// would rather name locally than discover as a 413 after a full upload. A var so
// the tests can shrink it rather than generate 100 MB to reach it.
var prebuiltMaxWireBytes int64 = 100 << 20

// prebuiltMaxUncompressedBytes is the belt to the wire cap's braces: a runaway
// walk (a `dist/` someone pointed at `/`) is stopped mid-copy by streamTarball's
// own budget instead of compressing for minutes first.
const prebuiltMaxUncompressedBytes int64 = 1 << 30

// prebuiltArtifact is a packed, on-disk artifact ready to upload: the temp file
// holding the exact bytes that will cross the wire, that byte count, and the
// sha256 OVER THOSE BYTES. All three exist before the connection is opened —
// which is the whole reason this path buffers instead of streaming from a pipe
// (charter D93): a piped upload is chunked (Content-Length -1), so the size can
// only be known after the last byte, the server cannot reject early, and the
// digest the box re-verifies could not be sent in the request that carries it.
type prebuiltArtifact struct {
	Path      string
	WireBytes int64
	SHA256    string
	// Cleanup removes the temp file. Always non-nil on success; call it deferred.
	Cleanup func()
}

// packPrebuiltDir validates a build-output directory and packs it into a temp
// tar.gz whose ROOT is that directory (so `index.html` lands at the archive root
// with no `dist/` prefix — the box extracts it straight into the release dir).
//
// The guards are here because the packer gives none of them: an empty
// directory packs SILENTLY into a valid, zero-entry archive that uploads and
// deploys to a 404; a project directory handed to --prebuilt by mistake packs
// the source instead of the output; and the wire cap is the server's, in the
// server's units.
//
// SYMLINKS ARE NOW A CLIENT-SIDE REFUSAL (charter D120, and this reverses the
// rationale that stood here). The old comment argued that the box's refusal was
// "the load-bearing one" and that refusing here would "only make the honest
// error arrive earlier" — that reasoning is about ESCAPING links, but the code
// emits EVERY link verbatim, and a CONTAINED `home.html -> index.html` (a
// hand-made pretty-URL alias) has no honest earlier error at all: it packs, it
// uploads against an already-minted nonced deployment, and only then does
// stage/4 answer E_SYMLINK "the archive contains a symlink — refused (a staged
// symlink is SERVED)" and throw the whole deploy away. The same dist deploys
// fine as an ON-BOX build, because that path copies with `cp -a`. So the seam
// is closed at the client: what the box will refuse never leaves the laptop.
func packPrebuiltDir(dir string) (prebuiltArtifact, error) {
	abs, err := validatePrebuiltDir(dir)
	if err != nil {
		return prebuiltArtifact{}, err
	}
	root := strings.TrimSpace(dir)

	art, err := bufferTarball(tarballOptions{
		Root:     abs,
		Ignores:  prebuiltTarballIgnores,
		MaxBytes: prebuiltMaxUncompressedBytes,
	})
	if err != nil {
		return prebuiltArtifact{}, err
	}
	if art.WireBytes > prebuiltMaxWireBytes {
		art.Cleanup()
		return prebuiltArtifact{}, fmt.Errorf("packed artifact is %d bytes on the wire, over the %d-byte upload cap — a built dist/ is normally kilobytes, so check that --prebuilt %s points at the build output", art.WireBytes, prebuiltMaxWireBytes, root)
	}
	return art, nil
}

// validatePrebuiltDir is the network-free half of packPrebuiltDir: every refusal
// that must happen BEFORE the CLI mints a deployment, let alone opens an upload.
// It returns the absolute, SYMLINK-RESOLVED path on success.
//
// It is called from TWO places and that is deliberate: cloud_site_cmd.go's
// deploy branch calls it PRE-MINT (above siteCloudConfig/resolveOpenSiteID, so a
// bad dir can never mint a deployment) and packPrebuiltDir calls it again on the
// way to the packer. So the per-entry walk below runs TWICE per deploy. That is
// intentional, not an oversight — a built dist/ is kilobytes, and "fixing" it by
// moving the walk into packPrebuiltDir would silently lose the PRE-MINT arm,
// which is the only one that runs before the nonce is spent. The two call sites
// render the same error differently (pre-mint is usage/exitUsage, post-mint is
// failed/exitGeneric); since the pre-mint arm always fires first on the real
// command, a refusal from here surfaces as usage/exitUsage.
func validatePrebuiltDir(dir string) (string, error) {
	root := strings.TrimSpace(dir)
	if root == "" {
		return "", fmt.Errorf("--prebuilt needs a directory (e.g. --prebuilt ./dist)")
	}
	abs, err := filepath.Abs(root)
	if err != nil {
		return "", fmt.Errorf("abs %q: %w", root, err)
	}
	info, err := os.Stat(abs)
	if err != nil {
		return "", fmt.Errorf("--prebuilt %s: %w", root, err)
	}
	if !info.IsDir() {
		return "", fmt.Errorf("--prebuilt %s is not a directory — pass the build OUTPUT directory (e.g. ./dist)", root)
	}
	// RESOLVE THE ROOT. `dist -> packages/site/dist` is the monorepo shape, and
	// os.Stat/os.ReadDir both FOLLOW it — so every guard below passes while
	// filepath.Walk, which LSTATS the root, sees a non-directory, calls its walkFn
	// once with rel="." and stops. Measured on main: a 32-byte, ZERO-entry archive
	// that uploads against a nonced deployment and comes back E_MALFORMED "the
	// archive holds no entries". Handing the resolved path to the packer makes the
	// tree pack instead, and D93's non-empty guard stops being bypassable.
	resolved, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", fmt.Errorf("--prebuilt %s: resolving the directory failed: %w", root, err)
	}
	abs = resolved
	entries, err := os.ReadDir(abs)
	if err != nil {
		return "", fmt.Errorf("read %q: %w", root, err)
	}
	if len(entries) == 0 {
		return "", fmt.Errorf("--prebuilt %s is empty — nothing to deploy (did the build run, and did it write here?)", root)
	}
	// A root index.html is what the static runtime serves and what HEALTH reads
	// its markers out of. Without it the deploy would go green on bytes that 404.
	idx, err := os.Stat(filepath.Join(abs, "index.html"))
	if err != nil || !idx.Mode().IsRegular() {
		return "", fmt.Errorf("--prebuilt %s has no index.html at its root — that is the build OUTPUT directory (e.g. ./dist), not the project directory", root)
	}
	if err := preflightPrebuiltEntries(abs, root); err != nil {
		return "", err
	}
	return abs, nil
}

// prebuiltAcceptedTypeflags is the box's own accept list, transcribed from
// `type/1` in api/lib/barkpark/sites/prebuilt_artifact.ex: a regular file ('0' or
// the historical NUL), a directory ('5'), and the pax extension header ('x').
// EVERY other byte at offset 156 of a 512-byte block is a typed refusal there —
// '2' E_SYMLINK, '1' E_HARDLINK, '3'/'4'/'6' E_SPECIAL_FILE, and the remaining
// extension headers ('g' pax GLOBAL, 'L'/'K' the GNU long-name pair)
// E_UNKNOWN_TYPE.
//
// 'x' IS IN THE LIST ON PURPOSE, and getting this wrong would have re-broken the
// exact lane this wave exists to open. `archive/tar` elects a pax header for any
// non-ASCII name and for any path component that cannot be split under 100
// bytes, so REFUSING 'x' here means refusing to deploy a Norwegian blog — the
// headline defect, merely relocated from the box to the laptop. The extractor
// admits 'x' narrowly as of this wave (only the `path` and `size` records are
// applied, and the effective name then re-enters the whole of name/1 AND
// safe_path/2), which is what makes it safe to let these bytes leave.
//
// 'x' is an accepted HEADER, not a stageable entry — hence "accepted", not
// "stageable". BOX-LAGS-CLI (charter D112) is a supported product state, so a box
// that predates the extractor's pax arm still answers E_UNKNOWN_TYPE for these
// bytes; the client cannot know the box's version and must not pre-emptively
// refuse a name that every current box stages. That refusal now reaches the user
// with its code and message intact (FailureCopy.typed_refusal?/1), which is the
// honest way for a version skew to surface.
var prebuiltAcceptedTypeflags = map[byte]struct{}{
	'0': {}, 0: {}, '5': {}, 'x': {},
}

// preflightPrebuiltEntries is the per-entry, NETWORK-FREE half of the seam: for
// every entry the packer would actually emit, it asks THE SAME ENCODER what byte
// lands at offset 156 and refuses anything the box would refuse — locally, by
// name, before a deployment is minted.
//
// It shares writeTarball's walk, its ignore set and its header construction by
// CONSTRUCTION (walkTarballEntries + tarballIgnoreSet + tarHeaderFor), not by
// copy. Sharing the CONTROL FLOW is load-bearing, not tidiness: a naive walk
// flags `.git/refs/heads/café-branch` while the real packer never emits it,
// because the ignore arm returns filepath.SkipDir on a directory.
func preflightPrebuiltEntries(abs, root string) error {
	return walkTarballEntries(abs, tarballIgnoreSet(abs, prebuiltTarballIgnores), func(path, rel string, info os.FileInfo) error {
		name := filepath.ToSlash(rel)
		hdr, err := tarHeaderFor(path, rel, info)
		if err != nil {
			return err
		}
		// Symlinks are answered BEFORE the dry encode. The encode would also catch
		// them (typeflag '2'), but a link whose TARGET is over 100 bytes elects a
		// PAX header instead and the verdict would name the less useful reason.
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("--prebuilt %s: %s is a symlink to %q — the box refuses a staged symlink outright (E_SYMLINK: \"the archive contains a symlink — refused (a staged symlink is SERVED)\"), so these bytes would be thrown away AFTER the deployment is minted. Replace it with a real file — %s — or emit the alias from your build; an on-box build accepts it only because that path copies with `cp -a`", root, name, hdr.Linkname, symlinkReplaceHint(root, name, hdr.Linkname))
		}
		flag, blockBytes, err := observedTarTypeflag(hdr)
		if err != nil {
			return fmt.Errorf("--prebuilt %s: %s cannot be written into a tar archive at all: %w", root, name, err)
		}
		if _, ok := prebuiltAcceptedTypeflags[flag]; ok {
			return nil
		}
		if flag == 'g' || flag == 'L' || flag == 'K' {
			return fmt.Errorf("--prebuilt %s: %s encodes as a %d-byte %s extension header (typeflag %q), and the box's extractor refuses that one (E_UNKNOWN_TYPE: unsupported tar entry type) — unlike the pax 'x' header, whose name it applies and re-validates. Repack in POSIX/pax format (`tar --format=posix …`; GNU tar defaults to `--format=gnu`), or shorten the path component that is over 100 bytes", root, name, blockBytes, map[byte]string{'g': "pax GLOBAL", 'L': "GNU long-name", 'K': "GNU long-linkname"}[flag], string(flag))
		}
		return fmt.Errorf("--prebuilt %s: %s encodes as tar typeflag %q, which the box's extractor refuses — only regular files and directories are staged. Remove it from the build output", root, name, string(flag))
	})
}

// symlinkReplaceHint renders a COPY-PASTEABLE command that replaces one symlink
// with the bytes it points at. The subtlety it exists for: a relative link target
// is resolved against the LINK'S OWN DIRECTORY, not against the dist root, so
// for `assets/home.html -> index.html` the source is `assets/index.html` and a
// naive `cp index.html assets/home.html` copies the WRONG file (the root
// index.html) — silently, and only on nested links, which is the shape a
// pretty-URL alias actually takes.
//
// `name` is the slash-separated archive name, `link` the raw target. An absolute
// or root-escaping target gets no cp at all: copying it in would stage bytes from
// outside the dist, which is exactly the exfiltration D120 refuses.
func symlinkReplaceHint(root, name, link string) string {
	if link == "" || path.IsAbs(link) {
		return "its target is an ABSOLUTE path OUTSIDE the build output, so there is no copy to suggest: emit the file into the dist instead"
	}
	src := path.Join(path.Dir(name), link)
	if src == ".." || strings.HasPrefix(src, "../") {
		return "its target resolves OUTSIDE " + root + ", so there is no copy to suggest: copying it in would stage bytes from outside the build output"
	}
	return fmt.Sprintf("cd %s && cp %s %s", root, src, name)
}

// observedTarTypeflag is a DRY ENCODE, and that is the whole point: Go's
// USTAR-vs-PAX election lives in the unexported Header.allowedFormats, so any
// hand-written predicate forks stdlib internals — and gets it wrong. The trigger
// is UNSPLITTABILITY, not length: measured on go1.26.2, a 141-byte path that
// splits at a '/' takes no PAX, while a 121-byte single directory component
// does, and the PAX header lands on the DIRECTORY entry rather than the leaf.
//
// So we ask the same encoder the packer uses and READ THE BYTE the extractor
// reads: offset 156 of the first 512-byte block. tar.Writer emits header blocks
// on WriteHeader and body bytes only on Write, and we never Write and never
// Close — so this costs exactly one block for a well-formed name (three for a
// PAX name) regardless of the file's size, opens no file and no socket.
func observedTarTypeflag(hdr *tar.Header) (byte, int, error) {
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	if err := tw.WriteHeader(hdr); err != nil {
		return 0, 0, err
	}
	b := buf.Bytes()
	if len(b) < 512 {
		return 0, len(b), fmt.Errorf("tar header encoded to %d bytes, expected at least one 512-byte block", len(b))
	}
	return b[156], len(b), nil
}

// bufferTarball packs opts into a temp file and returns the wire byte count plus
// the sha256 over those exact bytes.
//
// A NIL Ignores list is REFUSED rather than defaulted: nil is the one value that
// silently reaches loadGitignore and the payload-deleting project defaults, and
// this helper exists precisely for the payload those defaults delete. The empty
// slice is a different hazard (it ignores nothing, `.env` included), so the
// caller must state its list either way.
func bufferTarball(opts tarballOptions) (prebuiltArtifact, error) {
	if opts.Ignores == nil {
		return prebuiltArtifact{}, fmt.Errorf("refusing to pack with a nil ignore list: nil means the project defaults (dist, build, out, .next, .astro, _build — the payload itself), and an empty list means nothing is ignored at all, including .env; pass an explicit list")
	}
	body, err := streamTarball(opts)
	if err != nil {
		return prebuiltArtifact{}, err
	}
	defer body.Close()

	f, err := os.CreateTemp("", "bp-prebuilt-*.tar.gz")
	if err != nil {
		return prebuiltArtifact{}, fmt.Errorf("create temp artifact: %w", err)
	}
	cleanup := func() { _ = os.Remove(f.Name()) }

	h := sha256.New()
	n, cerr := io.Copy(io.MultiWriter(f, h), body)
	closeErr := f.Close()
	if cerr != nil {
		cleanup()
		return prebuiltArtifact{}, cerr
	}
	if closeErr != nil {
		cleanup()
		return prebuiltArtifact{}, fmt.Errorf("write temp artifact: %w", closeErr)
	}
	return prebuiltArtifact{
		Path:      f.Name(),
		WireBytes: n,
		SHA256:    hex.EncodeToString(h.Sum(nil)),
		Cleanup:   cleanup,
	}, nil
}

// tarballOptions tunes the tar+gzip helper. `Root` is the directory to archive
// (cwd when empty); `Ignores` is the path-suffix / basename list filtered out
// (defaults applied when nil); `MaxBytes` is a defensive cap — when the
// uncompressed payload exceeds it we abort with an error so a runaway
// includes-everything tarball doesn't silently waste 30s of upload bandwidth.
type tarballOptions struct {
	Root     string
	Ignores  []string
	MaxBytes int64
}

// streamTarball returns a reader that emits a gzip'd tar of `opts.Root`. The
// archive runs in a goroutine: each file is opened, a tar header written, the
// contents streamed, and any read error closes the pipe so the upload errors
// honestly instead of hanging.
//
// Symlinks are written as symlinks (no follow). Directories carry a header
// entry so an empty dir survives a round trip. The archive is content-addressed
// only by path — there is no manifest, no checksum file; the builder is the
// next link in the chain.
func streamTarball(opts tarballOptions) (io.ReadCloser, error) {
	root := opts.Root
	if root == "" {
		cwd, err := os.Getwd()
		if err != nil {
			return nil, fmt.Errorf("getwd: %w", err)
		}
		root = cwd
	}
	root, err := filepath.Abs(root)
	if err != nil {
		return nil, fmt.Errorf("abs %q: %w", root, err)
	}
	info, err := os.Stat(root)
	if err != nil {
		return nil, fmt.Errorf("stat %q: %w", root, err)
	}
	if !info.IsDir() {
		return nil, fmt.Errorf("%q is not a directory", root)
	}

	ignoreSet := tarballIgnoreSet(root, opts.Ignores)

	pr, pw := io.Pipe()
	go func() {
		_ = pw.CloseWithError(writeTarball(pw, root, ignoreSet, opts.MaxBytes))
	}()
	return pr, nil
}

// tarballIgnoreSet normalizes an ignore list into the lookup set isIgnored
// consumes. `ignores` is NIL-SENSITIVE: nil means "fall back to the project's
// .gitignore plus the defaults", which is a different payload from an empty
// slice ("ignore nothing"), so the nil arm lives here rather than in a caller.
//
// Keys are normalized to a basename-or-suffix shape. We deliberately keep this
// simple — no glob support, no negation — to match the documented "default
// ignore list" shape. A user who needs glob handling can pre-build the tarball
// and pass --artifact-url.
func tarballIgnoreSet(root string, ignores []string) map[string]struct{} {
	if ignores == nil {
		ignores = loadGitignore(root)
	}
	ignoreSet := make(map[string]struct{}, len(ignores))
	for _, p := range ignores {
		p = strings.TrimSpace(p)
		if p == "" || strings.HasPrefix(p, "#") {
			continue
		}
		ignoreSet[strings.TrimRight(p, "/")] = struct{}{}
	}
	return ignoreSet
}

// walkTarballEntries is THE walk: it visits exactly the entries the packer
// emits, in the packer's order, applying the packer's ignore arm — including the
// filepath.SkipDir on an ignored DIRECTORY, which is why an ignored `.git` never
// contributes a single entry. The preflight and the packer share this function
// so the two can never disagree about what is in the archive.
func walkTarballEntries(root string, ignores map[string]struct{}, visit func(path, rel string, info os.FileInfo) error) error {
	return filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if rel == "." {
			return nil
		}
		if isIgnored(rel, ignores) {
			if info.IsDir() {
				return filepath.SkipDir
			}
			return nil
		}
		return visit(path, rel, info)
	})
}

// tarHeaderFor builds the EXACT header the packer writes for one walked entry —
// shared with the preflight so a dry encode elects the same tar format the wire
// bytes will.
func tarHeaderFor(path, rel string, info os.FileInfo) (*tar.Header, error) {
	link := ""
	if info.Mode()&os.ModeSymlink != 0 {
		var err error
		link, err = os.Readlink(path)
		if err != nil {
			return nil, fmt.Errorf("readlink %q: %w", path, err)
		}
	}
	hdr, err := tar.FileInfoHeader(info, link)
	if err != nil {
		return nil, err
	}
	// Use forward-slash relative paths so the archive is portable across
	// builder OSes (the builder runs Linux containers).
	hdr.Name = filepath.ToSlash(rel)
	if info.IsDir() {
		hdr.Name += "/"
	}
	return hdr, nil
}

// writeTarball is the goroutine body — walks `root`, writes each file into the
// tar+gzip pipeline, and closes both writers cleanly.
func writeTarball(w io.Writer, root string, ignores map[string]struct{}, maxBytes int64) error {
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	written := int64(0)

	err := walkTarballEntries(root, ignores, func(path, rel string, info os.FileInfo) error {
		hdr, err := tarHeaderFor(path, rel, info)
		if err != nil {
			return err
		}

		if err := tw.WriteHeader(hdr); err != nil {
			return err
		}
		if !info.Mode().IsRegular() {
			return nil
		}

		f, err := os.Open(path)
		if err != nil {
			return fmt.Errorf("open %q: %w", path, err)
		}
		// Bound the per-file copy so a single oversized file can't stream all
		// its bytes into the live upload before we notice. LimitReader caps the
		// overshoot at one byte past the remaining budget — just enough to trip
		// the `written > maxBytes` check below without emitting the whole file.
		var n int64
		if maxBytes > 0 {
			budget := maxBytes - written
			n, err = io.Copy(tw, io.LimitReader(f, budget+1))
		} else {
			n, err = io.Copy(tw, f)
		}
		_ = f.Close()
		if err != nil {
			return fmt.Errorf("copy %q: %w", path, err)
		}
		written += n
		if maxBytes > 0 && written > maxBytes {
			return fmt.Errorf("tarball uncompressed size exceeds %d bytes — refusing to upload (add a .gitignore to trim build outputs, or pass --artifact-url)", maxBytes)
		}
		return nil
	})
	if err != nil {
		_ = tw.Close()
		_ = gz.Close()
		return err
	}
	if err := tw.Close(); err != nil {
		_ = gz.Close()
		return err
	}
	return gz.Close()
}

// isIgnored reports whether a relative path inside the project root matches
// the ignore set. We check the basename, the full relative path, and any path
// segment — so an entry "node_modules" filters `node_modules/foo` AND
// `pkg/node_modules/bar`, which is what users expect from a "default ignore
// list".
func isIgnored(rel string, ignores map[string]struct{}) bool {
	if _, ok := ignores[rel]; ok {
		return true
	}
	base := filepath.Base(rel)
	if _, ok := ignores[base]; ok {
		return true
	}
	parts := strings.Split(filepath.ToSlash(rel), "/")
	for _, p := range parts {
		if _, ok := ignores[p]; ok {
			return true
		}
	}
	return false
}

// loadGitignore reads `<root>/.gitignore` when present, returning each
// non-comment line. A missing file falls back to the default ignore list — the
// "deploy a fresh `create-next-app` directory" case still works.
func loadGitignore(root string) []string {
	f, err := os.Open(filepath.Join(root, ".gitignore"))
	if err != nil {
		return defaultTarballIgnores
	}
	defer f.Close()
	var lines []string
	scanner := bufio.NewScanner(f)
	// Raise the max token size to 1MB so an over-long .gitignore line doesn't
	// silently stop the scan (same hardening the SSE readers use).
	scanner.Buffer(make([]byte, 0, 64*1024), 1<<20)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		// We don't support negation; an explicit "!foo" silently drops to
		// "include all". The fallback default list is added so common build
		// outputs (.next, node_modules) are still filtered for a project
		// whose .gitignore is unusually permissive.
		if strings.HasPrefix(line, "!") {
			continue
		}
		lines = append(lines, line)
	}
	// A read error or an over-long line (past the 1MB cap) stops Scan early with
	// a partial list. Keep the entries parsed so far and layer the defaults on
	// top — a union only ever excludes MORE, which is the safe direction. (The
	// old behaviour discarded already-parsed user entries like `secrets/`, the
	// opposite of the stated goal.)
	if err := scanner.Err(); err != nil {
		return append(lines, defaultTarballIgnores...)
	}
	// Always layer the defaults on top — a project's .gitignore may not list
	// .git/ but we still don't want to ship the VCS dir.
	lines = append(lines, defaultTarballIgnores...)
	return lines
}
