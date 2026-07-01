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
	"compress/gzip"
	"fmt"
	"io"
	"os"
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
	".env.local",
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

	ignores := opts.Ignores
	if ignores == nil {
		ignores = loadGitignore(root)
	}
	ignoreSet := make(map[string]struct{}, len(ignores))
	for _, p := range ignores {
		p = strings.TrimSpace(p)
		if p == "" || strings.HasPrefix(p, "#") {
			continue
		}
		// Normalize to a basename-or-suffix key. We deliberately keep this
		// simple — no glob support, no negation — to match the documented
		// "default ignore list" shape. A user who needs glob handling can
		// pre-build the tarball and pass --artifact-url.
		ignoreSet[strings.TrimRight(p, "/")] = struct{}{}
	}

	pr, pw := io.Pipe()
	go func() {
		_ = pw.CloseWithError(writeTarball(pw, root, ignoreSet, opts.MaxBytes))
	}()
	return pr, nil
}

// writeTarball is the goroutine body — walks `root`, writes each file into the
// tar+gzip pipeline, and closes both writers cleanly.
func writeTarball(w io.Writer, root string, ignores map[string]struct{}, maxBytes int64) error {
	gz := gzip.NewWriter(w)
	tw := tar.NewWriter(gz)
	written := int64(0)

	err := filepath.Walk(root, func(path string, info os.FileInfo, walkErr error) error {
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

		link := ""
		if info.Mode()&os.ModeSymlink != 0 {
			link, err = os.Readlink(path)
			if err != nil {
				return fmt.Errorf("readlink %q: %w", path, err)
			}
		}

		hdr, err := tar.FileInfoHeader(info, link)
		if err != nil {
			return err
		}
		// Use forward-slash relative paths so the archive is portable across
		// builder OSes (the builder runs Linux containers).
		hdr.Name = filepath.ToSlash(rel)
		if info.IsDir() {
			hdr.Name += "/"
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
		n, err := io.Copy(tw, f)
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
	// a partial list — fall back to the safe defaults rather than shipping files
	// the user meant to exclude.
	if err := scanner.Err(); err != nil {
		return defaultTarballIgnores
	}
	// Always layer the defaults on top — a project's .gitignore may not list
	// .git/ but we still don't want to ship the VCS dir.
	lines = append(lines, defaultTarballIgnores...)
	return lines
}
