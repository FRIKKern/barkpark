package setup

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

// localServerURL is where a local bring-up lands; CONNECT points bp here after a
// successful run.
const localServerURL = "http://localhost:4000"

// localRepoURL is what a curl-installed bp (no checkout anywhere above cwd)
// clones to bring up a local server. Mirrors deploy.sh's REPO.
const localRepoURL = "https://github.com/FRIKKern/barkpark.git"

// executeLocal brings up a local Barkpark dev server — either via docker-compose
// (plan.Docker) or the native Elixir/Postgres toolchain — then points bp at it
// and applies the plugin selection.
//
// DRY-RUN-FIRST: a dry run prints the ordered step plan + the exact commands
// WITHOUT running anything. A real run requires opts.Confirm because these steps
// reset a database (mix ecto.reset / ecto.create+seed) — never auto-run a
// destructive bring-up without an explicit confirm.
func executeLocal(plan SetupPlan, opts Options) error {
	w := opts.out()

	envValue, envSet := PluginsEnvValue(plan.Plugins)
	profile := plan.profileOrDefault()
	lc := resolveLocalContext()

	if opts.DryRun {
		// JSON dry-run is rendered by the caller from BuildPlan; print nothing.
		// No token is generated on a dry run — the seed step's EnvLine shows the
		// redacted placeholder.
		if !opts.json() {
			steps := localSteps(plan, lc, envValue, envSet, "")
			mode := "native toolchain"
			if plan.Docker {
				mode = "docker compose"
			}
			heading := fmt.Sprintf("setup local (%s) — would bring up a dev server at %s", mode, localServerURL)
			printPlan(w, heading, localStepsAsSteps(steps))
			fmt.Fprintf(w, "\n  profile: %s\n", profileSummary(profile))
			fmt.Fprintf(w, "  plugins: %s\n", PluginsSummary(plan.Plugins))
			fmt.Fprintf(w, "  then:    connect bp to %s (no execution — dry run)\n", localServerURL)
		}
		return nil
	}

	// Real run gate: these steps reset a DB.
	if !opts.Confirm {
		return fmt.Errorf("setup local resets a database (%s) — re-run with --yes to confirm, or --dry-run to preview", destructiveStepName(plan))
	}

	// Dependency preflight before mutating anything. A missing REQUIRED dep
	// errors with the exact per-OS install command — bp prints it, it NEVER runs
	// brew/apt itself. Warn-only deps (vips) print and continue.
	for _, c := range localPreflight(plan, lc) {
		if c.present {
			continue
		}
		if !c.required {
			if !opts.json() {
				fmt.Fprintf(w, "  warning: %s — %s\n", c.missing, c.hint())
			}
			continue
		}
		return fmt.Errorf("setup local: %s\n  %-13s %s\n  %-13s bp setup --target local%s --yes",
			c.missing, c.action+":", c.hint(), "then re-run:", dockerFlagSuffix(plan))
	}

	// Clean profile: mint the admin token NOW (execute time, never plan time)
	// so the seed installs it and the chained connect persists it verified.
	adminToken := ""
	if profile == ProfileClean {
		tok, terr := GenerateAdminToken()
		if terr != nil {
			return fmt.Errorf("setup local: %w", terr)
		}
		adminToken = tok
	}
	steps := localSteps(plan, lc, envValue, envSet, adminToken)

	ctx := context.Background()
	for _, s := range steps {
		if s.WaitFor != nil {
			// A WaitFor step may still carry a Cmd for the dry-run display; the
			// closure is the real action (background start, health poll, …).
			if err := s.WaitFor(ctx, w); err != nil {
				return err
			}
			continue
		}
		if err := runStep(ctx, w, s.step); err != nil {
			return err
		}
	}

	// One-time admin-token banner: the seed installed this token; show it once
	// BEFORE the connect chain so a failed connect never swallows it.
	if adminToken != "" && !opts.json() {
		fmt.Fprintf(w, "\n  admin token (shown once — store it now):\n")
		fmt.Fprintf(w, "    %s\n", adminToken)
		fmt.Fprintf(w, "  it is also saved to %s (0600) by the connect step below\n", configHint())
	}

	// Bring-up succeeded — point bp here and apply the plugin selection by
	// reusing the CONNECT executor. The generated admin token (clean profile)
	// rides as the connection's bearer so the tier probe verifies it live.
	if !opts.json() {
		fmt.Fprintf(w, "\n>> Connecting bp to %s\n", localServerURL)
	}
	connectPlan := SetupPlan{
		Target:    TargetConnect,
		Server:    localServerURL,
		Token:     plan.Token,
		Workspace: plan.Workspace,
		Project:   plan.Project,
		Dataset:   plan.Dataset,
		Profile:   profile,
	}
	if adminToken != "" {
		connectPlan.Token = adminToken
	}
	// Wire a Result even on the human path so the tier the probe resolved is
	// verifiable below (the JSON caller's pointer, when present, is reused).
	connOpts := opts
	var connResult Result
	if connOpts.Result == nil {
		connOpts.Result = &connResult
	}
	if err := executeConnect(connectPlan, connOpts); err != nil {
		return err
	}
	if adminToken != "" {
		// The probe ran with the freshly-minted token; anything below admin means
		// the seed did not install it (e.g. an existing unrevoked admin token made
		// the bootstrap skip). Surface it instead of silently saving a weak tier.
		if tier := connOpts.Result.Tier; tier != "admin" {
			return fmt.Errorf("setup local: generated admin token resolved tier %q, want admin — the seed may have skipped the token bootstrap (an unrevoked admin token already exists?)", tier)
		}
	}
	// Native path: the server bp started dies with the machine; teach the
	// restart line (with the plugin whitelist that must ride along).
	if !plan.Docker && !opts.json() {
		restart := "mix phx.server"
		if envSet {
			restart = "BARKPARK_PLUGINS=" + envValue + " " + restart
		}
		fmt.Fprintf(w, "\n  restart later with: cd %s && %s\n", lc.apiDir, restart)
	}
	// The chained connect recorded a Result with target=connect; re-stamp it as
	// the outer "local" target so a JSON caller sees the mode it actually ran.
	if opts.Result != nil {
		opts.Result.Target = TargetLocal
	}
	return nil
}

// buildLocalPlan builds the structured dry-run plan for the local bring-up. It
// mirrors the human plan exactly: the ordered bring-up steps, the plugin env,
// the destructive flag (it resets a DB), the dependency needs, and the
// connect-to target.
func buildLocalPlan(plan SetupPlan, _ Options) Plan {
	envValue, envSet := PluginsEnvValue(plan.Plugins)
	profile := plan.profileOrDefault()
	lc := resolveLocalContext()
	steps := localSteps(plan, lc, envValue, envSet, "") // no token at plan time

	p := Plan{
		Target:          TargetLocal,
		DryRun:          true,
		Destructive:     true, // resets a database
		RequiresConfirm: true, // --yes gates the real run
		Plugins:         planPlugins(plan.Plugins),
		Profile:         profile,
		ConnectTo:       localServerURL,
		Env:             map[string]string{"BARKPARK_SEED_PROFILE": profile},
	}
	if profile == ProfileClean {
		// Generated at execute time; the plan only ever shows the redaction.
		p.Env["BARKPARK_SEED_ADMIN_TOKEN"] = "****"
	}
	if envSet {
		p.Env["BARKPARK_PLUGINS"] = envValue
	}
	for _, c := range localPreflight(plan, lc) {
		p.Needs = append(p.Needs, PlanNeed{What: c.what, Present: c.present})
	}
	for _, s := range steps {
		p.addStep(s.Title, planCommand(s.step))
	}
	return p
}

// profileSummary renders the one-line human description of a seed profile for
// dry-run / confirm screens.
func profileSummary(profile string) string {
	if profile == ProfileDemo {
		return "demo (8 schemas, 27 docs)"
	}
	return "clean (papers + media)"
}

// planCommand renders a step's displayable command line for the structured plan
// (env prefix + cmd), or "" for narration-only steps.
func planCommand(s step) string {
	if s.Cmd == "" {
		return ""
	}
	if s.EnvLine != "" {
		return s.EnvLine + " " + s.Cmd
	}
	return s.Cmd
}

// localStep wraps a plan step with an optional inline wait closure. Docker
// bring-up needs a "wait for the db to be healthy" beat that is not a single
// shell command; WaitFor handles it inline while still appearing in the dry-run
// plan as narration.
type localStep struct {
	step
	WaitFor func(ctx context.Context, w writerLike) error
}

// writerLike is the minimal writer the wait closures need (io.Writer).
type writerLike = interface{ Write(p []byte) (int, error) }

// ── repo self-sufficiency ────────────────────────────────────────────────────

// localContext resolves WHERE the local bring-up runs: an existing checkout
// found above cwd, or the managed clone at ${BARKPARK_HOME:-~/.barkpark}/src
// for a curl-installed bp with no checkout anywhere.
type localContext struct {
	root     string // repo root every step runs under
	apiDir   string // <root>/api
	clone    bool   // no checkout found — a clone/pull step is prepended
	cloneNew bool   // clone=true and root does not exist yet (git clone vs pull)
}

// resolveLocalContext finds a checkout via locateRepo, else targets the managed
// clone dir (existing dir → pull --ff-only, absent → fresh shallow clone).
func resolveLocalContext() localContext {
	if root, err := locateRepo(); err == nil {
		return localContext{root: root, apiDir: filepath.Join(root, "api")}
	}
	root := filepath.Join(barkparkHome(), "src")
	lc := localContext{root: root, apiDir: filepath.Join(root, "api"), clone: true, cloneNew: true}
	if st, err := os.Stat(root); err == nil && st.IsDir() {
		lc.cloneNew = false
	}
	return lc
}

// locateRepo walks up from cwd (bounded, like locateDeployScript) looking for a
// barkpark checkout, identified by api/mix.exs. Returns the repo root.
func locateRepo() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for i := 0; i < 8; i++ {
		cand := filepath.Join(dir, "api", "mix.exs")
		if st, serr := os.Stat(cand); serr == nil && !st.IsDir() {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	return "", fmt.Errorf("no barkpark checkout (api/mix.exs) found above %s", dir)
}

// barkparkHome is ${BARKPARK_HOME:-~/.barkpark} — the same convention
// bin/barkpark-pg uses (docs/setup/personal-local.md).
func barkparkHome() string {
	if h := strings.TrimSpace(os.Getenv("BARKPARK_HOME")); h != "" {
		return h
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return ".barkpark"
	}
	return filepath.Join(home, ".barkpark")
}

// phxLogPath is where the background Phoenix server's output lands.
func phxLogPath() string {
	return filepath.Join(barkparkHome(), "phx.log")
}

// ── dependency preflight ─────────────────────────────────────────────────────

// depCheck is one preflight prerequisite: what it is, whether it was found, a
// short "what's wrong" line, the action verb, and the per-OS install hints. bp
// only ever PRINTS the hint — running package managers from a Go binary is a
// support trap (sudo, Homebrew prompts, PATH drift), so there is no
// --install-deps and never will be in v1.
type depCheck struct {
	what     string
	present  bool
	required bool   // false = warn-only (vips)
	missing  string // "mix (Elixir) not found on PATH"
	action   string // "install it" / "install + start it"
	darwin   string
	linux    string
}

// hint returns the per-OS install command for this dependency.
func (c depCheck) hint() string {
	if runtime.GOOS == "darwin" {
		return c.darwin
	}
	return c.linux
}

// dockerFlagSuffix keeps the re-run hint faithful to the chosen mode.
func dockerFlagSuffix(plan SetupPlan) string {
	if plan.Docker {
		return " --docker"
	}
	return ""
}

// localPreflight builds the ordered dependency checks for the chosen path.
// Docker: docker CLI + a running daemon. Native: mix, postgres answering on
// :5432 (required), vips (warn-only — image derivatives degrade without it).
// git is required on either path when the repo must be cloned.
func localPreflight(plan SetupPlan, lc localContext) []depCheck {
	var checks []depCheck
	if lc.clone {
		checks = append(checks, depCheck{
			what:     "git",
			present:  lookExec("git"),
			required: true,
			missing:  "`git` not found on PATH (needed to clone the barkpark repo)",
			action:   "install it",
			darwin:   "xcode-select --install",
			linux:    "sudo apt-get install -y git",
		})
	}
	if plan.Docker {
		checks = append(checks, depCheck{
			what:     "docker (daemon running)",
			present:  lookExec("docker") && dockerDaemonUp(),
			required: true,
			missing:  "docker is not available (CLI missing or the daemon is not running)",
			action:   "install + start it",
			darwin:   "install Docker Desktop (https://www.docker.com/products/docker-desktop) and start it",
			linux:    "curl -fsSL https://get.docker.com | sh && sudo systemctl start docker",
		})
		return checks
	}
	checks = append(checks,
		depCheck{
			what:     "mix (Elixir)",
			present:  lookExec("mix"),
			required: true,
			missing:  "`mix` (Elixir) not found on PATH",
			action:   "install it",
			darwin:   "brew install elixir",
			linux:    "sudo apt-get install -y elixir erlang-dev",
		},
		depCheck{
			what:     "postgres on localhost:5432",
			present:  tcpAnswering("localhost:5432"),
			required: true,
			missing:  "postgres is not answering on localhost:5432",
			action:   "install + start it",
			darwin:   "brew install postgresql@17 && brew services start postgresql@17",
			linux:    "sudo apt-get install -y postgresql postgresql-contrib && sudo systemctl start postgresql",
		},
		depCheck{
			what:     "vips (image processing)",
			present:  lookExec("vips"),
			required: false, // warn-only: media uploads work, derivatives degrade
			missing:  "`vips` not found on PATH (media image derivatives will be degraded)",
			action:   "install it",
			darwin:   "brew install vips",
			linux:    "sudo apt-get install -y libvips-dev libvips-tools",
		},
	)
	return checks
}

// tcpAnswering reports whether something accepts a TCP connection at addr
// within a short dial timeout (the postgres liveness probe).
func tcpAnswering(addr string) bool {
	conn, err := net.DialTimeout("tcp", addr, 1500*time.Millisecond)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}

// dockerDaemonUp reports whether `docker info` succeeds (CLI present AND the
// daemon answering).
func dockerDaemonUp() bool {
	_, err := runCapture(context.Background(), "docker", "info")
	return err == nil
}

// ── step plans ───────────────────────────────────────────────────────────────

// cloneStep is the prepended bring-up step when no checkout exists: a fresh
// shallow clone into the managed dir, or a fast-forward pull on a re-run.
func cloneStep(lc localContext) localStep {
	if lc.cloneNew {
		return localStep{step: step{
			Title: "clone the barkpark repo (no checkout found above the working directory)",
			Cmd:   fmt.Sprintf("git clone --depth 1 %s %s", localRepoURL, lc.root),
			Argv:  []string{"git", "clone", "--depth", "1", localRepoURL, lc.root},
		}}
	}
	return localStep{step: step{
		Title: "update the managed barkpark clone (fast-forward only)",
		Cmd:   fmt.Sprintf("git -C %s pull --ff-only", lc.root),
		Argv:  []string{"git", "-C", lc.root, "pull", "--ff-only"},
	}}
}

// localSteps builds the ordered bring-up plan for either path, every step
// rooted at the resolved checkout (lc.root / lc.apiDir). Every command is
// rendered for the dry run; the destructive DB step is explicit so the confirm
// gate message can name it. adminToken is the freshly-generated clean-profile
// token on a real run, "" at plan/dry-run time — the seed step's EnvLine always
// shows the redacted **** so the live value never echoes.
func localSteps(plan SetupPlan, lc localContext, envValue string, envSet bool, adminToken string) []localStep {
	pluginEnv := ""
	var pluginRealEnv []string
	if envSet {
		pluginEnv = "BARKPARK_PLUGINS=" + envValue
		pluginRealEnv = []string{"BARKPARK_PLUGINS=" + envValue}
	}
	profile := plan.profileOrDefault()

	// Seed env: the display line (redacted) and the real process env.
	seedEnvLine := "BARKPARK_SEED_PROFILE=" + profile
	seedEnv := []string{"BARKPARK_SEED_PROFILE=" + profile}
	if profile == ProfileClean {
		seedEnvLine += " BARKPARK_SEED_ADMIN_TOKEN=****"
		if adminToken != "" {
			seedEnv = append(seedEnv, "BARKPARK_SEED_ADMIN_TOKEN="+adminToken)
		}
	}

	var steps []localStep
	if lc.clone {
		steps = append(steps, cloneStep(lc))
	}

	if plan.Docker {
		// docker compose exec threads the seed env via -e NAME=value (the display
		// Cmd redacts the token; the Argv carries the live value).
		seedArgv := []string{"docker", "compose", "exec", "-T"}
		seedCmd := "docker compose exec"
		seedCmd += " -e BARKPARK_SEED_PROFILE=" + profile
		seedArgv = append(seedArgv, "-e", "BARKPARK_SEED_PROFILE="+profile)
		if profile == ProfileClean {
			seedCmd += " -e BARKPARK_SEED_ADMIN_TOKEN=****"
			if adminToken != "" {
				seedArgv = append(seedArgv, "-e", "BARKPARK_SEED_ADMIN_TOKEN="+adminToken)
			}
		}
		seedArgv = append(seedArgv, "api", "mix", "ecto.reset")
		seedCmd += " api mix ecto.reset"
		return append(steps,
			localStep{step: step{
				Title:   "start containers (db + api) in the background",
				Cmd:     "docker compose up -d",
				Argv:    []string{"docker", "compose", "up", "-d"},
				Dir:     lc.root,
				EnvLine: pluginEnv,
				Env:     pluginRealEnv, // compose passes it through (bare `- BARKPARK_PLUGINS`)
			}},
			localStep{
				step: step{Title: "wait for the postgres container to become healthy"},
				WaitFor: func(ctx context.Context, w writerLike) error {
					return waitDockerDBHealthy(ctx, w, lc.root)
				},
			},
			localStep{step: step{
				Title: "reset + seed the database (drop, create, migrate, seed)",
				Cmd:   seedCmd,
				Argv:  seedArgv,
				Dir:   lc.root,
			}},
			localStep{
				step: step{Title: "wait for the API to answer on " + localServerURL},
				WaitFor: func(ctx context.Context, w writerLike) error {
					return waitServerUp(ctx, w, localServerURL, 120*time.Second)
				},
			},
		)
	}

	// Native path.
	return append(steps,
		localStep{step: step{
			Title: "verify Elixir/mix is installed",
			Cmd:   "mix --version",
			Argv:  []string{"mix", "--version"},
		}},
		localStep{step: step{
			Title: "fetch Elixir deps",
			Cmd:   "mix deps.get",
			Argv:  []string{"mix", "deps.get"},
			Dir:   lc.apiDir,
		}},
		localStep{step: step{
			Title:   "reset + seed the database (drop, create, migrate, seed)",
			Cmd:     "mix ecto.reset",
			Argv:    []string{"mix", "ecto.reset"},
			Dir:     lc.apiDir,
			EnvLine: seedEnvLine,
			Env:     seedEnv,
		}},
		localStep{
			step: step{
				Title:   "start Phoenix in the background on :4000 (logs: " + phxLogPath() + ")",
				Cmd:     "mix phx.server",
				Dir:     lc.apiDir,
				EnvLine: pluginEnv,
			},
			// runStep would BLOCK on mix phx.server (cmd.Run waits forever), so the
			// real action is a detached background start + the capabilities poll
			// below — verified at build time, exactly the nohup+poll fallback the
			// plan specified.
			WaitFor: func(ctx context.Context, w writerLike) error {
				return startPhoenixBackground(w, lc.apiDir, pluginRealEnv)
			},
		},
		localStep{
			step: step{Title: "wait for the API to answer on " + localServerURL},
			WaitFor: func(ctx context.Context, w writerLike) error {
				// Generous: the first dev boot compiles the whole Phoenix app.
				return waitServerUp(ctx, w, localServerURL, 300*time.Second)
			},
		},
	)
}

// startPhoenixBackground starts `mix phx.server` detached (own session, output
// to ~/.barkpark/phx.log) so it survives bp exiting, and returns immediately —
// waitServerUp gates the connect chain on the server actually answering.
func startPhoenixBackground(w writerLike, apiDir string, env []string) error {
	logPath := phxLogPath()
	if err := os.MkdirAll(filepath.Dir(logPath), 0o755); err != nil {
		return fmt.Errorf("create %s: %w", filepath.Dir(logPath), err)
	}
	f, err := os.OpenFile(logPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return fmt.Errorf("open phx log %s: %w", logPath, err)
	}
	defer f.Close()

	cmd := backgroundCommand("mix", "phx.server")
	cmd.Dir = apiDir
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}
	cmd.Stdout = f
	cmd.Stderr = f
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start mix phx.server: %w", err)
	}
	fmt.Fprintf(asWriter(w), ">> Started Phoenix in the background (pid %d, logs: %s)\n", cmd.Process.Pid, logPath)
	go func() { _ = cmd.Wait() }() // reap if it dies while bp is still running
	return nil
}

// waitServerUp polls GET <baseURL>/v1/capabilities until a 2xx or the timeout.
// It is the readiness gate between the bring-up steps and the connect chain.
func waitServerUp(ctx context.Context, w writerLike, baseURL string, timeout time.Duration) error {
	fmt.Fprintf(asWriter(w), ">> Waiting for %s/v1/capabilities to answer…\n", baseURL)
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 3 * time.Second}
	for time.Now().Before(deadline) {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		resp, err := client.Get(baseURL + "/v1/capabilities")
		if err == nil {
			resp.Body.Close()
			if resp.StatusCode >= 200 && resp.StatusCode < 300 {
				fmt.Fprintln(asWriter(w), "   server is up")
				return nil
			}
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for %s to answer (check the logs: %s)", baseURL, phxLogPath())
}

// localStepsAsSteps projects []localStep down to []step for the shared dry-run
// renderer (the WaitFor closures carry no display state beyond their Title).
func localStepsAsSteps(in []localStep) []step {
	out := make([]step, len(in))
	for i, s := range in {
		out[i] = s.step
	}
	return out
}

// destructiveStepName returns the human name of the DB-resetting step for the
// confirm-gate error message.
func destructiveStepName(plan SetupPlan) string {
	if plan.Docker {
		return "docker compose exec api mix ecto.reset"
	}
	return "mix ecto.reset"
}

// waitDockerDBHealthy polls `docker compose ps` (in the compose project dir)
// until the db service reports healthy (or a timeout). It is the inline beat
// between `up -d` and the seed so the seed never races a not-yet-ready postgres.
func waitDockerDBHealthy(ctx context.Context, w writerLike, dir string) error {
	fmt.Fprintln(asWriter(w), ">> Waiting for the postgres container to become healthy…")
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		out, err := runCaptureDir(ctx, dir, "docker", "compose", "ps", "--format", "{{.Service}} {{.Health}}")
		if err == nil && strings.Contains(out, "db healthy") {
			fmt.Fprintln(asWriter(w), "   db healthy")
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for the postgres container to become healthy")
}

// backgroundCommand builds an exec.Cmd detached into its own session (Setsid)
// so the child outlives bp's exit and never holds the terminal.
func backgroundCommand(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	return cmd
}
