// Package assets embeds the repo's deploy.sh, entra-app-register.sh and
// deploy/azure so a curl-installed bp (no
// checkout anywhere near cwd) can still stream the installer over SSH.
//
// The CANONICAL script stays at the repo root (`ssh … 'bash -s' < deploy.sh`
// docs keep working); this copy exists only because go:embed cannot reach
// outside the package directory. `make cli-build` / `make cli-release` run
// `make cli-assets-sync` (a cp) before building, and `make cli-assets-check`
// (a cmp, wired into the cli-release workflow) fails the build on drift.
// Do not edit assets/deploy.sh by hand — edit /deploy.sh and re-sync.
package assets

import "embed"

// DeployScript is the embedded copy of the repo-root deploy.sh. The deploy
// executor prefers a checkout's script (operators testing local edits) and
// falls back to this, written to a 0700 temp file for the stream.
//
//go:embed deploy.sh
var DeployScript []byte

// EntraScript is the embedded copy of scripts/entra-app-register.sh. `bp
// instance up` runs it to register the Entra app when no Bicep module does.
//
//go:embed entra-app-register.sh
var EntraScript []byte

// Azure holds the embedded copy of deploy/azure: main.bicep, its modules and
// main.example.bicepparam. `bp instance up --path containerapps` deploys it.
//
//go:embed azure
var Azure embed.FS
