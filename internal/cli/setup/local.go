package setup

import (
	"context"
	"fmt"
	"strings"
	"time"
)

// localServerURL is where a local bring-up lands; CONNECT points bp here after a
// successful run.
const localServerURL = "http://localhost:4000"

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

	if opts.DryRun {
		// JSON dry-run is rendered by the caller from BuildPlan; print nothing.
		// No token is generated on a dry run — the seed step's EnvLine shows the
		// redacted placeholder.
		if !opts.json() {
			steps := localSteps(plan, envValue, envSet, "")
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

	// Presence checks before mutating anything.
	if plan.Docker {
		if !lookExec("docker") {
			return fmt.Errorf("setup local --docker: `docker` not found on PATH\n  install Docker Desktop / engine, then re-run")
		}
	} else {
		if !lookExec("mix") {
			return fmt.Errorf("setup local: `mix` (Elixir) not found on PATH\n  install Elixir (https://elixir-lang.org/install.html), then re-run")
		}
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
	steps := localSteps(plan, envValue, envSet, adminToken)

	ctx := context.Background()
	for _, s := range steps {
		if s.WaitFor != nil {
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
	// The chained connect recorded a Result with target=connect; re-stamp it as
	// the outer "local" target so a JSON caller sees the mode it actually ran.
	if opts.Result != nil {
		opts.Result.Target = TargetLocal
	}
	return nil
}

// buildLocalPlan builds the structured dry-run plan for the local bring-up. It
// mirrors the human plan exactly: the ordered bring-up steps, the plugin env,
// the destructive flag (it resets a DB), and the connect-to target.
func buildLocalPlan(plan SetupPlan, _ Options) Plan {
	envValue, envSet := PluginsEnvValue(plan.Plugins)
	profile := plan.profileOrDefault()
	steps := localSteps(plan, envValue, envSet, "") // no token at plan time

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

// localSteps builds the ordered bring-up plan for either path. Every command is
// rendered for the dry run; the destructive DB step is explicit so the confirm
// gate message can name it. adminToken is the freshly-generated clean-profile
// token on a real run, "" at plan/dry-run time — the seed step's EnvLine always
// shows the redacted **** so the live value never echoes.
func localSteps(plan SetupPlan, envValue string, envSet bool, adminToken string) []localStep {
	pluginEnv := ""
	if envSet {
		pluginEnv = "BARKPARK_PLUGINS=" + envValue
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
		return []localStep{
			{step: step{
				Title:   "start containers (db + api) in the background",
				Cmd:     "docker compose up -d",
				Argv:    []string{"docker", "compose", "up", "-d"},
				EnvLine: pluginEnv,
			}},
			{
				step: step{Title: "wait for the postgres container to become healthy"},
				WaitFor: func(ctx context.Context, w writerLike) error {
					return waitDockerDBHealthy(ctx, w)
				},
			},
			{step: step{
				Title: "reset + seed the database (drop, create, migrate, seed)",
				Cmd:   seedCmd,
				Argv:  seedArgv,
			}},
		}
	}

	// Native path.
	return []localStep{
		{step: step{
			Title: "verify Elixir/mix is installed",
			Cmd:   "mix --version",
			Argv:  []string{"mix", "--version"},
		}},
		{step: step{
			Title: "fetch Elixir deps",
			Cmd:   "mix deps.get",
			Argv:  []string{"mix", "deps.get"},
			Dir:   "api",
		}},
		{step: step{
			Title:   "reset + seed the database (drop, create, migrate, seed)",
			Cmd:     "mix ecto.reset",
			Argv:    []string{"mix", "ecto.reset"},
			Dir:     "api",
			EnvLine: seedEnvLine,
			Env:     seedEnv,
		}},
		{step: step{
			Title:   "start Phoenix in the background on :4000",
			Cmd:     "mix phx.server",
			Argv:    []string{"mix", "phx.server"},
			Dir:     "api",
			EnvLine: pluginEnv,
		}},
	}
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

// waitDockerDBHealthy polls `docker compose ps` until the db service reports
// healthy (or a timeout). It is the inline beat between `up -d` and the seed so
// the seed never races a not-yet-ready postgres.
func waitDockerDBHealthy(ctx context.Context, w writerLike) error {
	fmt.Fprintln(asWriter(w), ">> Waiting for the postgres container to become healthy…")
	deadline := time.Now().Add(60 * time.Second)
	for time.Now().Before(deadline) {
		out, err := runCapture(ctx, "docker", "compose", "ps", "--format", "{{.Service}} {{.Health}}")
		if err == nil && strings.Contains(out, "db healthy") {
			fmt.Fprintln(asWriter(w), "   db healthy")
			return nil
		}
		time.Sleep(2 * time.Second)
	}
	return fmt.Errorf("timed out waiting for the postgres container to become healthy")
}
