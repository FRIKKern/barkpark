package cli

import (
	"encoding/json"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

// vercel_cmd.go is `bp vercel quick-setup` — the one-shot "stand up a new
// Barkpark-backed site and ship it to Vercel" flow. It is the Go port of
// scripts/bp-vercel-quick-setup.sh (see templates/DEPLOYING.md → "Folding into
// the CLI"). A CLI-native BUILT-IN (dispatched from Execute, not the manifest
// tree) for the same reason `migrate` / `paper` are: it composes a multi-step
// provisioning + deploy pipeline the generic command runner knows nothing
// about, and it resolves the target server + admin token through the saved-
// server config exactly like the other built-ins.
//
// The big change versus the shell script: the read token is minted over HTTPS
// via the admin-gated POST /w/<site>/p/default/v1/tokens endpoint — NO ssh into
// prod. Vercel stays a shell-out to the `vercel` binary (link → disable
// protection → env → deploy), guarded by a presence check.
//
// Steps (quick-setup):
//   1. workspace create (POST /api/workspaces) → capture id; conflict → look up.
//   2. schema apply  → POST scoped /v1/schemas/:dataset   (SCOPED prefix, NOT flat).
//   3. seed + publish → POST scoped /v1/data/mutate/:dataset (publish needs {id,type}).
//   4. read token    → POST scoped /v1/tokens (the Part A endpoint) → capture token.
//   5. vercel link → disable deployment protection → env → deploy --prod.
//   6. --no-deploy stops after step 4 and prints the read token + read URL.

const vercelDefaultProject = "default"    // Barkpark project slug under a new workspace
const vercelDefaultDataset = "production" // default dataset

// parsedVercelArgs holds the resolved `vercel quick-setup` flags.
type parsedVercelArgs struct {
	site          string
	appDir        string
	schema        string
	seed          string
	publishType   string
	dataset       string
	vercelTeam    string
	vercelProject string // defaults to site (or the --static basename)
	readToken     string // supply directly to skip minting
	noDeploy      bool
	static        string // STATIC mode: a dir or single .html file — skip ALL Barkpark steps
	help          bool
}

// runVercel is the `bp vercel <subcommand>` built-in entry. v1 ships exactly one
// subcommand — `quick-setup`. A bare `bp vercel` (or `-h`) prints usage. tail is
// everything after the `vercel` noun (rest[1:] in Execute).
func runVercel(out *writer, g globals, tail []string) int {
	if len(tail) == 0 {
		usageVercel(out, g.help)
		if g.help {
			return exitOK
		}
		return exitUsage
	}

	sub := tail[0]
	switch sub {
	case "quick-setup":
		return runVercelQuickSetup(out, g, tail[1:])
	case "-h", "--help", "help":
		usageVercel(out, true)
		return exitOK
	default:
		out.userErr("unknown vercel subcommand %q", sub)
		usageVercel(out, false)
		return exitUsage
	}
}

// runVercelQuickSetup parses flags then drives the new-site flow.
//
// Output: like every other built-in, an explicit `-o json`/`-o yaml` (resolved
// into out.output by applyGlobals) switches this from the human progress view to
// a single machine-readable envelope. In machine mode the step-by-step chatter
// routes to stderr (via out.progressf) so stdout carries exactly ONE parseable
// document — the terminal {ok,site,url,read_token,…} envelope a scripted
// provision consumes. Human (table) mode is byte-identical to before.
func runVercelQuickSetup(out *writer, g globals, args []string) int {
	machine := out.machineOut()

	opt, err := parseVercelArgs(args)
	if err != nil {
		if machine {
			return vercelFail(out, true, "usage", err.Error(), exitUsage)
		}
		out.userErr("%v", err)
		usageVercel(out, false)
		return exitUsage
	}
	if opt.help {
		usageVercel(out, true)
		return exitOK
	}

	// STATIC mode — a plain static site with NO Barkpark backend. Skip every
	// Barkpark step (workspace/schema/seed/publish/token) and run ONLY the
	// Vercel half. --site/--schema/--seed/--publish-type/--read-token are
	// ignored here; no BARKPARK_* env is set.
	if opt.static != "" {
		return runVercelStatic(out, opt)
	}

	if opt.site == "" {
		return vercelUsageError(out, machine, "--site is required")
	}
	if !opt.noDeploy && opt.appDir == "" {
		return vercelUsageError(out, machine, "--app-dir is required (unless --no-deploy)")
	}

	dataset := firstNonEmptyStr(opt.dataset, g.dataset, vercelDefaultDataset)
	project := vercelDefaultProject
	vercelProject := firstNonEmptyStr(opt.vercelProject, opt.site)

	// Resolve the target server + admin token through the SAME precedence as
	// every other command (flags > env > saved config > baked default).
	ctx := resolveContext(g)
	base := strings.TrimRight(ctx.Server, "/")
	adminToken := ctx.Token
	if adminToken == "" {
		return vercelFail(out, machine, "auth", "no admin token resolved — pass --token or run 'bp use <server>'", exitAuth)
	}

	scopedPrefix := vercelScopedPrefix(opt.site, project)
	scopedBase := base + scopedPrefix // …/w/<site>/p/default

	out.progressf("▸ quick-setup '%s' on %s (dataset=%s)", opt.site, base, dataset)

	// ── 1. workspace ─────────────────────────────────────────────────────────
	if err := vercelEnsureWorkspace(out, base, adminToken, opt.site); err != nil {
		return vercelFail(out, machine, "workspace", "workspace step failed: "+err.Error(), exitGeneric)
	}

	// ── 2. schema ────────────────────────────────────────────────────────────
	if opt.schema != "" {
		if err := vercelApplySchema(out, scopedBase, dataset, adminToken, opt.schema); err != nil {
			return vercelFail(out, machine, "schema", "schema apply failed: "+err.Error(), exitGeneric)
		}
	}

	// ── 3. seed + publish ────────────────────────────────────────────────────
	if opt.seed != "" {
		if err := vercelSeed(out, scopedBase, dataset, adminToken, opt.seed, opt.publishType); err != nil {
			return vercelFail(out, machine, "seed", "seed/publish failed: "+err.Error(), exitGeneric)
		}
	}

	// ── 4. read token (over HTTPS — no ssh) ──────────────────────────────────
	readToken := opt.readToken
	if readToken == "" {
		tok, err := vercelMintReadToken(out, scopedBase, dataset, adminToken, opt.site)
		if err != nil {
			return vercelFail(out, machine, "read_token", "read-token mint failed: "+err.Error(), exitGeneric)
		}
		readToken = tok
	} else {
		out.progressf("  ✓ using supplied --read-token")
	}

	// ── 5 + 6. Vercel ────────────────────────────────────────────────────────
	if opt.noDeploy {
		readQuery := fmt.Sprintf("%s/v1/data/query/%s/<type>?filter[status]=published", scopedBase, dataset)
		out.progressf("▸ --no-deploy — Barkpark provisioned, skipping Vercel")
		out.progressf("  read API:  %s", readQuery)
		// The read token is the single intended secret surface — print it once
		// so the operator can wire BARKPARK_TOKEN by hand.
		out.progressf("  read token (server-only env BARKPARK_TOKEN): %s", readToken)
		if machine {
			out.emitStructured(map[string]any{
				"ok":         true,
				"site":       opt.site,
				"dataset":    dataset,
				"api_url":    scopedBase,
				"read_query": readQuery,
				"read_token": readToken,
				"deployed":   false,
			})
		}
		return exitOK
	}

	liveURL, err := vercelDeploy(out, opt, scopedBase, dataset, vercelProject, readToken)
	if err != nil {
		return vercelFail(out, machine, "vercel", "vercel step failed: "+err.Error(), exitGeneric)
	}
	if machine {
		out.emitStructured(map[string]any{
			"ok":             true,
			"site":           opt.site,
			"dataset":        dataset,
			"api_url":        scopedBase,
			"read_token":     readToken,
			"url":            liveURL,
			"vercel_project": vercelProject,
			"deployed":       true,
		})
	}
	return exitOK
}

// vercelUsageError reports an argument-validation failure: a json/yaml error
// envelope in machine mode, else the human message plus the usage block.
func vercelUsageError(out *writer, machine bool, msg string) int {
	if machine {
		return vercelFail(out, true, "usage", msg, exitUsage)
	}
	out.userErr("%s", msg)
	usageVercel(out, false)
	return exitUsage
}

// vercelFail is the single failure seam for the vercel built-in. In machine mode
// it emits a {ok:false, error:{code,message}} envelope on stdout (matching the
// migrate/hetzner CLI convention) so a scripted caller sees a parseable failure;
// in human mode it writes the familiar `bp: …` line to stderr.
func vercelFail(out *writer, machine bool, code, msg string, exit int) int {
	if machine {
		out.emitStructured(map[string]any{
			"ok":    false,
			"error": map[string]any{"code": code, "message": msg},
		})
		return exit
	}
	out.userErr("%s", msg)
	return exit
}

// runVercelStatic handles the --static path: a plain static site with no
// Barkpark backend. It stages the deploy dir (a directory as-is, or a single
// .html file into a temp build dir as index.html, copying an adjacent
// assets/public dir if present), then runs ONLY the Vercel half — link →
// disable protection → deploy. No BARKPARK_* env vars are set.
func runVercelStatic(out *writer, opt parsedVercelArgs) int {
	machine := out.machineOut()

	deployDir, cleanup, err := vercelStageStatic(opt.static)
	if cleanup != nil {
		defer cleanup()
	}
	if err != nil {
		return vercelFail(out, machine, "static", "--static staging failed: "+err.Error(), exitGeneric)
	}

	// Project name: explicit --vercel-project, else the basename of the staged
	// source (dir name, or the html file name without extension).
	project := firstNonEmptyStr(opt.vercelProject, vercelStaticProjectName(opt.static))
	if project == "" {
		return vercelFail(out, machine, "usage", "could not derive a vercel project name — pass --vercel-project", exitUsage)
	}

	if _, lerr := exec.LookPath("vercel"); lerr != nil {
		return vercelFail(out, machine, "vercel", "the 'vercel' CLI is not on PATH (install it first)", exitGeneric)
	}

	scopeFlag := []string{}
	if opt.vercelTeam != "" {
		scopeFlag = []string{"--scope", opt.vercelTeam}
	}

	out.progressf("▸ Vercel static deploy '%s' (no Barkpark backend)", project)
	linkArgs := append([]string{"link", "--yes", "--project", project}, scopeFlag...)
	if lerr := vercelRun(out, deployDir, linkArgs...); lerr != nil {
		return vercelFail(out, machine, "vercel", "vercel link failed: "+lerr.Error(), exitGeneric)
	}
	out.progressf("  ✓ linked %s → %s", deployDir, project)

	vercelDisableProtection(out, deployDir)

	out.progressf("▸ Deploy to production")
	deployArgs := append([]string{"deploy", "--prod", "--yes"}, scopeFlag...)
	url, derr := vercelRunCapture(deployDir, deployArgs...)
	if derr != nil {
		return vercelFail(out, machine, "vercel", "vercel deploy failed: "+derr.Error(), exitGeneric)
	}
	url = extractDeployURL(url)
	if url == "" {
		return vercelFail(out, machine, "vercel", "deploy produced no URL", exitGeneric)
	}
	out.progressf("  ✓ deployed: %s", url)
	out.progressf("🚀 %s is live → %s", project, url)
	if machine {
		out.emitStructured(map[string]any{
			"ok":             true,
			"vercel_project": project,
			"url":            url,
			"static":         true,
			"deployed":       true,
		})
	}
	return exitOK
}

// vercelStageStatic resolves the --static source into a deployable directory.
// A directory is returned as-is (no cleanup). A single .html file is staged
// into a fresh temp dir as index.html; an adjacent assets/ or public/ dir is
// copied alongside. The returned cleanup removes the temp dir (nil for the
// directory case).
func vercelStageStatic(src string) (dir string, cleanup func(), err error) {
	fi, serr := os.Stat(src)
	if serr != nil {
		return "", nil, fmt.Errorf("--static '%s' not found", src)
	}
	if fi.IsDir() {
		return src, nil, nil
	}
	if !strings.EqualFold(filepath.Ext(src), ".html") {
		return "", nil, fmt.Errorf("--static '%s' must be a directory or a .html file", src)
	}

	tmp, terr := os.MkdirTemp("", "bp-vercel-static-")
	if terr != nil {
		return "", nil, terr
	}
	cleanup = func() { _ = os.RemoveAll(tmp) }

	data, rerr := os.ReadFile(src)
	if rerr != nil {
		return "", cleanup, fmt.Errorf("read %s: %w", src, rerr)
	}
	if werr := os.WriteFile(filepath.Join(tmp, "index.html"), data, 0o644); werr != nil {
		return "", cleanup, werr
	}

	// Copy an adjacent assets/ or public/ dir alongside the page, if present.
	parent := filepath.Dir(src)
	for _, sub := range []string{"assets", "public"} {
		from := filepath.Join(parent, sub)
		if dfi, derr := os.Stat(from); derr == nil && dfi.IsDir() {
			if cerr := vercelCopyDir(from, filepath.Join(tmp, sub)); cerr != nil {
				return "", cleanup, fmt.Errorf("copy %s/: %w", sub, cerr)
			}
		}
	}
	return tmp, cleanup, nil
}

// vercelStaticProjectName derives a default project name from the --static
// source: the directory name, or the html file name without its extension.
func vercelStaticProjectName(src string) string {
	base := filepath.Base(strings.TrimRight(src, string(filepath.Separator)))
	if strings.EqualFold(filepath.Ext(base), ".html") {
		base = strings.TrimSuffix(base, filepath.Ext(base))
	}
	if base == "." || base == "/" {
		return ""
	}
	return base
}

// vercelCopyDir recursively copies a directory tree (files + subdirs). Plain
// content copy — no symlink chasing — enough for static assets folders.
func vercelCopyDir(from, to string) error {
	return filepath.Walk(from, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, rerr := filepath.Rel(from, path)
		if rerr != nil {
			return rerr
		}
		dst := filepath.Join(to, rel)
		if info.IsDir() {
			return os.MkdirAll(dst, 0o755)
		}
		data, rerr := os.ReadFile(path)
		if rerr != nil {
			return rerr
		}
		if merr := os.MkdirAll(filepath.Dir(dst), 0o755); merr != nil {
			return merr
		}
		return os.WriteFile(dst, data, info.Mode().Perm())
	})
}

// vercelScopedPrefix builds the workspace/project SCOPED prefix — the path the
// whole flow drives provisioning against. It is DELIBERATELY scoped
// (`/w/<site>/p/<project>`), never the flat `/v1/…` alias: the flat alias
// resolves to the Default workspace, so writing there lands content in the wrong
// tenant (DEPLOYING.md gotcha #1).
func vercelScopedPrefix(site, project string) string {
	return fmt.Sprintf("/w/%s/p/%s", url.PathEscape(site), url.PathEscape(project))
}

func vercelAuthHeaders(token string) map[string]string {
	h := map[string]string{}
	if token != "" {
		h["Authorization"] = "Bearer " + token
	}
	return h
}

func vercelJSONHeaders(token string) map[string]string {
	h := vercelAuthHeaders(token)
	h["Content-Type"] = "application/json"
	return h
}

// vercelEnsureWorkspace creates the workspace (POST /api/workspaces); on a
// conflict (already exists) it falls through quietly — the flow is idempotent.
func vercelEnsureWorkspace(out *writer, base, token, site string) error {
	body, _ := json.Marshal(map[string]string{"name": site, "slug": site})
	status, respBody, err := doRequest("POST", base+"/api/workspaces", vercelJSONHeaders(token), body)
	if err != nil {
		return err
	}
	switch {
	case status >= 200 && status < 300:
		// Every ✓ in this deploy flow used to be printed off the STATUS alone —
		// respBody was read only on failure — so a proxy page interposed in
		// front of the target answered 200 and the operator watched six green
		// checkmarks over a deploy that wrote nothing.
		if serr := builtinWriteReceiptErr("workspace create", status, respBody); serr != nil {
			return serr
		}
		out.progressf("  ✓ workspace '%s' created", site)
		return nil
	case status == 409 || status == 422:
		// Already exists (duplicate slug) — idempotent, treat as present.
		out.progressf("  ✓ workspace '%s' already exists", site)
		return nil
	default:
		ae := classifyError(status, respBody)
		return fmt.Errorf("workspace create: status %d: %s", status, ae.errorMessage())
	}
}

// vercelApplySchema POSTs a flat schema object to the SCOPED schema URL.
func vercelApplySchema(out *writer, scopedBase, dataset, token, schemaFile string) error {
	data, err := os.ReadFile(schemaFile)
	if err != nil {
		return fmt.Errorf("read schema %s: %w", schemaFile, err)
	}
	u := scopedBase + "/v1/schemas/" + url.PathEscape(dataset)
	status, respBody, err := doRequest("POST", u, vercelJSONHeaders(token), data)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		return fmt.Errorf("schema apply: status %d: %s", status, ae.errorMessage())
	}
	if serr := builtinWriteReceiptErr("schema apply", status, respBody); serr != nil {
		return serr
	}
	out.progressf("  ✓ schema applied (%s)", filepath.Base(schemaFile))
	return nil
}

// vercelSeed POSTs the seed mutations to the SCOPED mutate URL, then — when a
// publishType is given — publishes every seeded doc id. The publish mutation
// requires BOTH id AND type (DEPLOYING.md gotcha #2).
func vercelSeed(out *writer, scopedBase, dataset, token, seedFile, publishType string) error {
	data, err := os.ReadFile(seedFile)
	if err != nil {
		return fmt.Errorf("read seed %s: %w", seedFile, err)
	}
	u := scopedBase + "/v1/data/mutate/" + url.PathEscape(dataset)
	status, respBody, err := doRequest("POST", u, vercelJSONHeaders(token), data)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		return fmt.Errorf("seed mutate: status %d: %s", status, ae.errorMessage())
	}
	if serr := builtinWriteReceiptErr("seed mutate", status, respBody); serr != nil {
		return serr
	}
	out.progressf("  ✓ seeded (createOrReplace lands as drafts)")

	if publishType == "" {
		return nil
	}

	ids, err := vercelSeedIDs(data)
	if err != nil {
		return err
	}
	pub := vercelPublishPayload(ids, publishType)
	pubBody, _ := json.Marshal(pub)
	status, respBody, err = doRequest("POST", u, vercelJSONHeaders(token), pubBody)
	if err != nil {
		return err
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		return fmt.Errorf("publish: status %d: %s", status, ae.errorMessage())
	}
	// len(ids) comes off the LOCAL seed file, not the response — the count is
	// not a measurement, so the receipt it appears in has to be.
	if serr := builtinWriteReceiptErr("publish", status, respBody); serr != nil {
		return serr
	}
	out.progressf("  ✓ published %d document(s) of type '%s'", len(ids), publishType)
	return nil
}

// vercelSeedIDs extracts the document ids from a seed payload's mutations,
// reading createOrReplace._id then create._id (matching the shell script's jq).
func vercelSeedIDs(seed []byte) ([]string, error) {
	var env struct {
		Mutations []struct {
			CreateOrReplace map[string]json.RawMessage `json:"createOrReplace"`
			Create          map[string]json.RawMessage `json:"create"`
		} `json:"mutations"`
	}
	if err := json.Unmarshal(seed, &env); err != nil {
		return nil, fmt.Errorf("parse seed mutations: %w", err)
	}
	var ids []string
	for _, m := range env.Mutations {
		if id := rawID(m.CreateOrReplace); id != "" {
			ids = append(ids, id)
			continue
		}
		if id := rawID(m.Create); id != "" {
			ids = append(ids, id)
		}
	}
	return ids, nil
}

// rawID pulls a string "_id" out of a mutation document map.
func rawID(doc map[string]json.RawMessage) string {
	if doc == nil {
		return ""
	}
	raw, ok := doc["_id"]
	if !ok {
		return ""
	}
	var s string
	if err := json.Unmarshal(raw, &s); err != nil {
		return ""
	}
	return s
}

// vercelPublishPayload builds the {"mutations":[{"publish":{"id","type"}}]} body.
// publish needs BOTH id and type, else the server 400s.
func vercelPublishPayload(ids []string, publishType string) map[string]any {
	muts := make([]map[string]any, 0, len(ids))
	for _, id := range ids {
		muts = append(muts, map[string]any{
			"publish": map[string]string{"id": id, "type": publishType},
		})
	}
	return map[string]any{"mutations": muts}
}

// vercelMintReadToken mints a read-only, workspace-bound token over HTTPS via the
// admin-gated POST /w/<site>/p/default/v1/tokens endpoint (Part A). This is the
// step that removes the only prod-ssh dependency from the old flow.
func vercelMintReadToken(out *writer, scopedBase, dataset, adminToken, site string) (string, error) {
	body, _ := json.Marshal(map[string]any{
		"label":       "public-read-" + site,
		"permissions": []string{"public-read"},
		"dataset":     dataset,
	})
	u := scopedBase + "/v1/tokens"
	status, respBody, err := doRequest("POST", u, vercelJSONHeaders(adminToken), body)
	if err != nil {
		return "", err
	}
	if status < 200 || status >= 300 {
		ae := classifyError(status, respBody)
		return "", fmt.Errorf("mint token: status %d: %s", status, ae.errorMessage())
	}
	var resp struct {
		Token string `json:"token"`
	}
	if jerr := json.Unmarshal(respBody, &resp); jerr != nil {
		return "", fmt.Errorf("parse mint response: %w", jerr)
	}
	// WRITE-FENCE EXEMPTION (builtinWriteCensus, dispCannotLie): this step's
	// whole product is the server's token string, so a body that said nothing
	// cannot produce a success.
	if resp.Token == "" {
		return "", fmt.Errorf("mint token: server returned no token")
	}
	// Never log the raw token here — only the label.
	out.progressf("  ✓ minted public-read-%s", site)
	return resp.Token, nil
}

// ── Vercel shell-out ─────────────────────────────────────────────────────────

// vercelDeploy runs link → disable-protection → env → deploy from --app-dir,
// shelling out to the `vercel` binary (guarded by a presence check). It returns
// the live deployment URL so the caller can fold it into a machine envelope.
func vercelDeploy(out *writer, opt parsedVercelArgs, scopedBase, dataset, project, readToken string) (string, error) {
	if _, err := exec.LookPath("vercel"); err != nil {
		return "", fmt.Errorf("the 'vercel' CLI is not on PATH (install it, or pass --no-deploy)")
	}
	if fi, err := os.Stat(opt.appDir); err != nil || !fi.IsDir() {
		return "", fmt.Errorf("--app-dir '%s' not found", opt.appDir)
	}

	scopeFlag := []string{}
	if opt.vercelTeam != "" {
		scopeFlag = []string{"--scope", opt.vercelTeam}
	}

	out.progressf("▸ Vercel project '%s'", project)
	linkArgs := append([]string{"link", "--yes", "--project", project}, scopeFlag...)
	if err := vercelRun(out, opt.appDir, linkArgs...); err != nil {
		return "", fmt.Errorf("vercel link failed (project name free / team correct?): %w", err)
	}
	out.progressf("  ✓ linked %s → %s", opt.appDir, project)

	// Disable deployment protection so the public site doesn't 302 to SSO login
	// (DEPLOYING.md gotcha #7). Best-effort — a failure is a warning, not fatal.
	vercelDisableProtection(out, opt.appDir)

	// Env (server-only — NO NEXT_PUBLIC_, so the token never reaches the browser).
	// Canonical unified names (task dwb-3): BARKPARK_API_URL carries the scoped
	// base URL, BARKPARK_TOKEN the server-only read token. Apps read these first,
	// with a fallback to the legacy BARKPARK_API_BASE / BARKPARK_API_TOKEN.
	vercelSetEnv(out, opt.appDir, scopeFlag, "BARKPARK_API_URL", scopedBase)
	vercelSetEnv(out, opt.appDir, scopeFlag, "BARKPARK_DATASET", dataset)
	vercelSetEnv(out, opt.appDir, scopeFlag, "BARKPARK_TOKEN", readToken)
	out.progressf("  ✓ env set (BARKPARK_API_URL, BARKPARK_DATASET, BARKPARK_TOKEN — server-only)")

	out.progressf("▸ Deploy to production")
	deployArgs := append([]string{"deploy", "--prod", "--yes"}, scopeFlag...)
	url, err := vercelRunCapture(opt.appDir, deployArgs...)
	if err != nil {
		return "", fmt.Errorf("vercel deploy failed: %w", err)
	}
	url = extractDeployURL(url)
	if url == "" {
		return "", fmt.Errorf("deploy produced no URL")
	}
	out.progressf("  ✓ deployed: %s", url)
	out.progressf("🚀 %s is live → %s", opt.site, url)
	return url, nil
}

// vercelSetEnv sets one env var for production + preview, removing any prior
// value first (vercel env add fails if the key already exists). Best-effort: a
// remove/add failure is silently tolerated, mirroring the shell script.
func vercelSetEnv(out *writer, appDir string, scopeFlag []string, name, value string) {
	for _, env := range []string{"production", "preview"} {
		rmArgs := append([]string{"env", "rm", name, env, "--yes"}, scopeFlag...)
		_ = vercelRunSilent(appDir, rmArgs...)
		addArgs := append([]string{"env", "add", name, env}, scopeFlag...)
		_ = vercelRunStdin(appDir, value, addArgs...)
	}
}

// vercelDisableProtection PATCHes the Vercel project to clear ssoProtection so
// the *.vercel.app URLs are public. Reads projectId/orgId from
// <app-dir>/.vercel/project.json and the CLI's own token from auth.json.
func vercelDisableProtection(out *writer, appDir string) {
	prjID, orgID, err := vercelProjectIDs(appDir)
	if err != nil || prjID == "" {
		out.progressf("  ! could not read .vercel/project.json — disable protection in Settings → Deployment Protection")
		return
	}
	vcToken := vercelCLIToken()
	if vcToken == "" {
		out.progressf("  ! no vercel CLI token found — disable protection in Settings → Deployment Protection")
		return
	}
	u := fmt.Sprintf("https://api.vercel.com/v9/projects/%s", url.PathEscape(prjID))
	if orgID != "" {
		u += "?teamId=" + url.QueryEscape(orgID)
	}
	body := []byte(`{"ssoProtection": null}`)
	status, _, derr := doRequest("PATCH", u, vercelJSONHeaders(vcToken), body)
	if derr != nil || status < 200 || status >= 300 {
		out.progressf("  ! could not auto-disable protection (status %d) — do it in Settings → Deployment Protection", status)
		return
	}
	out.progressf("  ✓ deployment protection off (public)")
}

// vercelProjectIDs reads projectId + orgId from <app-dir>/.vercel/project.json.
func vercelProjectIDs(appDir string) (projectID, orgID string, err error) {
	data, err := os.ReadFile(filepath.Join(appDir, ".vercel", "project.json"))
	if err != nil {
		return "", "", err
	}
	var pj struct {
		ProjectID string `json:"projectId"`
		OrgID     string `json:"orgId"`
	}
	if jerr := json.Unmarshal(data, &pj); jerr != nil {
		return "", "", jerr
	}
	return pj.ProjectID, pj.OrgID, nil
}

// vercelCLIToken reads the Vercel CLI's own token from auth.json, trying the
// macOS Application Support path, then XDG_DATA_HOME, then ~/.vercel.
func vercelCLIToken() string {
	for _, p := range vercelAuthPaths() {
		data, err := os.ReadFile(p)
		if err != nil {
			continue
		}
		var auth struct {
			Token string `json:"token"`
		}
		if json.Unmarshal(data, &auth) == nil && auth.Token != "" {
			return auth.Token
		}
	}
	return ""
}

// vercelAuthPaths returns the candidate auth.json locations in priority order.
func vercelAuthPaths() []string {
	home, _ := os.UserHomeDir()
	var paths []string
	if home != "" {
		paths = append(paths, filepath.Join(home, "Library", "Application Support", "com.vercel.cli", "auth.json"))
	}
	if xdg := os.Getenv("XDG_DATA_HOME"); xdg != "" {
		paths = append(paths, filepath.Join(xdg, "com.vercel.cli", "auth.json"))
	} else if home != "" {
		paths = append(paths, filepath.Join(home, ".local", "share", "com.vercel.cli", "auth.json"))
	}
	if home != "" {
		paths = append(paths, filepath.Join(home, ".vercel", "auth.json"))
	}
	return paths
}

// vercelRun runs `vercel <args>` in dir, forwarding the child's stderr to
// os.Stderr so vercel's own diagnostics (e.g. "Project not found", "not
// authenticated") reach the user; stdout is discarded (link/env produce noise
// we don't surface).
func vercelRun(out *writer, dir string, args ...string) error {
	cmd := exec.Command("vercel", args...)
	cmd.Dir = dir
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// vercelRunSilent runs vercel quietly, swallowing output and errors handled by caller.
func vercelRunSilent(dir string, args ...string) error {
	cmd := exec.Command("vercel", args...)
	cmd.Dir = dir
	return cmd.Run()
}

// vercelRunStdin runs vercel feeding value on stdin (vercel env add reads the
// value from stdin).
func vercelRunStdin(dir, value string, args ...string) error {
	cmd := exec.Command("vercel", args...)
	cmd.Dir = dir
	cmd.Stdin = strings.NewReader(value)
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// vercelRunCapture runs vercel and returns its combined stdout.
func vercelRunCapture(dir string, args ...string) (string, error) {
	cmd := exec.Command("vercel", args...)
	cmd.Dir = dir
	cmd.Stderr = os.Stderr
	b, err := cmd.Output()
	return string(b), err
}

// vercelDeployURLRe matches a deployment URL (…vercel.app), not the inspector
// (vercel.com) or API (api.vercel.com) URLs that also appear in JSON output.
var vercelDeployURLRe = regexp.MustCompile(`https://[A-Za-z0-9._-]+\.vercel\.app`)

// extractDeployURL pulls the deployment URL from `vercel deploy` output, which is
// plain text (URL on the final line) on some CLI versions and JSON (a
// "url": "….vercel.app" field) on others. Prefer the regex match; fall back to
// the last non-empty line.
func extractDeployURL(s string) string {
	if m := vercelDeployURLRe.FindString(s); m != "" {
		return m
	}
	return lastNonEmptyLine(s)
}

// lastNonEmptyLine returns the last non-blank line of s (vercel deploy prints the
// URL on its final line).
func lastNonEmptyLine(s string) string {
	lines := strings.Split(s, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if t := strings.TrimSpace(lines[i]); t != "" {
			return t
		}
	}
	return ""
}

// parseVercelArgs parses the quick-setup flags. Reuses the shared
// splitFlagToken/flagValue helpers (from migrate_cmd.go) so the flag grammar
// matches the rest of the CLI.
func parseVercelArgs(args []string) (parsedVercelArgs, error) {
	var p parsedVercelArgs
	i := 0
	for i < len(args) {
		a := args[i]
		key, inlineVal, hasInline := splitFlagToken(a)
		switch key {
		case "--site":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--site")
			if err != nil {
				return p, err
			}
			p.site, i = v, ni
		case "--app-dir":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--app-dir")
			if err != nil {
				return p, err
			}
			p.appDir, i = v, ni
		case "--schema":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--schema")
			if err != nil {
				return p, err
			}
			p.schema, i = v, ni
		case "--seed":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--seed")
			if err != nil {
				return p, err
			}
			p.seed, i = v, ni
		case "--publish-type":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--publish-type")
			if err != nil {
				return p, err
			}
			p.publishType, i = v, ni
		case "--dataset":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--dataset")
			if err != nil {
				return p, err
			}
			p.dataset, i = v, ni
		case "--vercel-team":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--vercel-team")
			if err != nil {
				return p, err
			}
			p.vercelTeam, i = v, ni
		case "--vercel-project":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--vercel-project")
			if err != nil {
				return p, err
			}
			p.vercelProject, i = v, ni
		case "--read-token":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--read-token")
			if err != nil {
				return p, err
			}
			p.readToken, i = v, ni
		case "--static":
			v, ni, err := flagValue(args, i, inlineVal, hasInline, "--static")
			if err != nil {
				return p, err
			}
			p.static, i = v, ni
		case "--no-deploy":
			p.noDeploy = true
			i++
		case "-h", "--help":
			p.help = true
			i++
		default:
			if strings.HasPrefix(a, "-") && a != "-" {
				return p, fmt.Errorf("unknown vercel flag %q", a)
			}
			return p, fmt.Errorf("unexpected argument %q", a)
		}
	}
	return p, nil
}

// usageVercel prints the vercel command signature. An explicit `--help` request
// routes to stdout (toStdout); the error paths keep it on stderr.
func usageVercel(out *writer, toStdout bool) {
	p := out.errf
	if toStdout {
		p = out.outf
	}
	p("usage: bp vercel quick-setup --site <slug> --app-dir <path> [flags]")
	p("       bp vercel quick-setup --static <path> [--vercel-project p] [--vercel-team t]")
	p("  stand up a new Barkpark-backed site and ship it to Vercel in one shot,")
	p("  or (--static) deploy a plain static site with NO Barkpark backend")
	p("")
	p("required (backed mode):")
	p("  --site <slug>           workspace + dataset name (e.g. hundesteder)")
	p("  --app-dir <path>        the Next.js app folder to deploy (unless --no-deploy)")
	p("")
	p("static mode (no Barkpark):")
	p("  --static <path>         deploy a dir as-is, or a single .html file (staged as")
	p("                          index.html, with an adjacent assets/ or public/ copied);")
	p("                          skips ALL Barkpark steps and sets NO BARKPARK_* env")
	p("")
	p("barkpark options:")
	p("  --schema <file.json>    schema to apply (flat schema object)")
	p("  --seed <file.json>      seed mutations {\"mutations\":[…]}")
	p("  --publish-type <type>   publish all seeded docs of this type after seeding")
	p("  --dataset <name>        dataset (default production)")
	p("  --read-token <tok>      use this read token, skip minting")
	p("")
	p("vercel options:")
	p("  --vercel-team <slug>    Vercel team/scope (e.g. guerrilla)")
	p("  --vercel-project <name> project name (default: --site)")
	p("  --no-deploy             provision Barkpark only, skip Vercel")
	p("")
	p("the admin token + server come from -s/--token/--server or the saved active server.")
}
