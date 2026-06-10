// Package assets embeds the repo's deploy.sh so a curl-installed bp (no
// checkout anywhere near cwd) can still stream the installer over SSH.
//
// The CANONICAL script stays at the repo root (`ssh … 'bash -s' < deploy.sh`
// docs keep working); this copy exists only because go:embed cannot reach
// outside the package directory. `make cli-build` / `make cli-release` run
// `make cli-assets-sync` (a cp) before building, and `make cli-assets-check`
// (a cmp, wired into the cli-release workflow) fails the build on drift.
// Do not edit assets/deploy.sh by hand — edit /deploy.sh and re-sync.
package assets

import _ "embed"

// DeployScript is the embedded copy of the repo-root deploy.sh. The deploy
// executor prefers a checkout's script (operators testing local edits) and
// falls back to this, written to a 0700 temp file for the stream.
//
//go:embed deploy.sh
var DeployScript []byte
