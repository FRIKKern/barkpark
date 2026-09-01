// Package deploy exposes committed on-box provisioning scripts as embedded
// bytes, so a Go binary can DELIVER one to a box it is configuring instead of
// assuming that box already holds a repo checkout at the right commit.
//
// Why embed rather than read from disk: the provisioner binary ships alone (no
// checkout beside it), and a managed box's own /opt/barkpark checkout is only
// ever "whatever freshen last brought it to" — a script read from there is not
// necessarily the script this binary was built and gated against. Embedding
// pins the two together at build time.
//
// The embed is a SAME-DIRECTORY reference to the one committed file, so there
// is no second copy that can drift out of step with the shell harness
// (deploy/site-runtime-install_test.sh, gated by
// .github/workflows/shell-harnesses.yml) that tests these exact bytes.
package deploy

import _ "embed"

// SiteRuntimeInstallScript is deploy/site-runtime-install.sh verbatim: the
// idempotent installer for a box's SITE-HOSTING PLANE — docker + buildx,
// nixpacks, an isolated Go toolchain, a shallow tools checkout, and the
// barkpark-builder / barkpark-runtime binaries with their systemd units.
//
// Two consumers read these bytes: the go-live chain's site-plane step
// (internal/cli/cloud.siteRuntimeInstallStep, which streams them over the
// warm-pool SSH seam) and the manual per-box cp-ops `site-runtime-install`
// operation (which scp's the file itself). Both therefore install the same
// plane from the same source.
//
//go:embed site-runtime-install.sh
var SiteRuntimeInstallScript string
