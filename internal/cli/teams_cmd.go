package cli

import (
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// teams_cmd.go — the CLI team-identity switcher (BP-ONB-02). The control plane
// already tracks EVERY team a user belongs to (GET /v1/me → teams[]) and the SPA
// renders a switcher over it, but `bp` had no equivalent: cfg.CloudTeam was
// written once at login and never user-switchable, so a human in more than one
// team was stranded acting as their signup team. These two verbs close that:
//
//	bp teams            list every membership (table + -o json), star the active one
//	bp team use <id|slug>  switch the active team; persists cfg.CloudTeam
//
// The active team is the identity context team-scoped Cloud calls run in — most
// visibly `bp instance credentials <id> --team …` (below) and, via the
// X-Barkpark-Team header, any session-token call the control plane honours it on.

// runTeams is `bp teams` — list the caller's team memberships. It reads the
// authoritative list from GET /v1/me (never a local cache) so a freshly-accepted
// invite shows up immediately, and marks the active team (cfg.CloudTeam) with a
// star so the switch state is legible at a glance.
func runTeams(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printTeamsHelp(out)
			return exitOK
		}
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	me, err := cfg.CloudClient().Me(cloudCtx())
	if err != nil {
		return cloudFail(out, "list teams", err)
	}

	active := strings.TrimSpace(cfg.CloudTeam)

	if out.output == "json" || out.output == "yaml" {
		rows := make([]map[string]any, 0, len(me.Teams))
		for _, t := range me.Teams {
			rows = append(rows, map[string]any{
				"id":     t.ID,
				"name":   t.Name,
				"slug":   t.Slug,
				"role":   t.Role,
				"active": teamMatches(t, active),
			})
		}
		out.emitStructured(map[string]any{
			"teams":       rows,
			"active_team": active,
		})
		return exitOK
	}

	if len(me.Teams) == 0 {
		out.outf("no team memberships yet — this account belongs to no team.")
		return exitOK
	}

	headers := []string{"", "NAME", "SLUG", "ROLE", "ID"}
	rows := make([][]string, 0, len(me.Teams))
	for _, t := range me.Teams {
		star := ""
		if teamMatches(t, active) {
			star = "*"
		}
		rows = append(rows, []string{star, hzCell(t.Name), hzCell(t.Slug), hzCell(t.Role), hzCell(t.ID)})
	}
	renderHzTable(out, headers, rows)
	out.outf("")
	out.outf("* = active team. Switch with 'bp team use <slug|id>'.")
	return exitOK
}

// runTeam is `bp team <verb> …`. Today the only verb is `use`:
//
//	bp team use <id|slug>
//
// which switches the active team the Cloud commands run in. `bp team` with no
// verb prints help (and is a usage error so a bare invocation exits non-zero).
func runTeam(out *writer, args []string) int {
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printTeamHelp(out)
			return exitOK
		}
	}

	if len(args) == 0 {
		printTeamHelp(out)
		return exitUsage
	}

	switch args[0] {
	case "use", "switch":
		return runTeamUse(out, args[1:])
	default:
		return useError(out, "usage", fmt.Sprintf("unknown team verb %q — try: bp team use <slug|id>", args[0]), exitUsage)
	}
}

// runTeamUse switches the active team. It takes a team SLUG or UUID, resolves it
// against the caller's membership list from GET /v1/me — the control plane's
// get_team/1 is UUID-only, so a slug can only be turned into its UUID here,
// client-side — and persists the resolved UUID to cfg.CloudTeam via SaveConfig.
// A slug/id the user is NOT a member of is refused with the honest list of the
// teams they CAN switch to (no silent write of an unknown team).
func runTeamUse(out *writer, args []string) int {
	var target string
	for _, a := range args {
		if a == "" || strings.HasPrefix(a, "-") {
			continue
		}
		target = a
		break
	}
	if target == "" {
		return useError(out, "usage", "bp team use <slug|id> — the team to switch to (see 'bp teams')", exitUsage)
	}

	cfg, ok := requireCloud(out)
	if !ok {
		return exitAuth
	}

	me, err := cfg.CloudClient().Me(cloudCtx())
	if err != nil {
		return cloudFail(out, "switch team", err)
	}

	match, found := resolveTeam(me.Teams, target)
	if !found {
		msg := fmt.Sprintf("not a member of team %q", target)
		if names := teamHandles(me.Teams); names != "" {
			msg += " — you can switch to: " + names
		}
		return useError(out, "failed", msg, exitGeneric)
	}

	cfg.CloudTeam = match.ID
	if err := SaveConfig(cfg); err != nil {
		return useError(out, "failed", "save config: "+err.Error(), exitGeneric)
	}

	if out.emitStructured(map[string]any{
		"ok":   true,
		"team": map[string]any{"id": match.ID, "name": match.Name, "slug": match.Slug, "role": match.Role},
	}) {
		return exitOK
	}

	label := match.Name
	if match.Slug != "" {
		label = fmt.Sprintf("%s (%s)", match.Name, match.Slug)
	}
	out.outf("Active team is now %s.", label)
	out.outf("Team-scoped Cloud calls (e.g. 'bp instance credentials <id>') now run as this team.")
	return exitOK
}

// resolveTeam finds the membership matching target (a slug OR a UUID), case-
// insensitively on the slug. Returns the full Team so the caller persists the
// canonical UUID even when the user typed the slug.
func resolveTeam(teams []cloudclient.Team, target string) (cloudclient.Team, bool) {
	t := strings.TrimSpace(target)
	for _, team := range teams {
		if team.ID == t || strings.EqualFold(team.Slug, t) {
			return team, true
		}
	}
	return cloudclient.Team{}, false
}

// teamMatches reports whether team is the active one — active is the persisted
// cfg.CloudTeam, which is a UUID, but we also accept a slug match so a
// hand-edited config (slug-valued) still highlights correctly.
func teamMatches(team cloudclient.Team, active string) bool {
	if active == "" {
		return false
	}
	return team.ID == active || strings.EqualFold(team.Slug, active)
}

// teamHandles renders the switch-to hint: each team's slug (or id when slugless),
// comma-joined, for the "you can switch to: …" line on a bad target.
func teamHandles(teams []cloudclient.Team) string {
	handles := make([]string, 0, len(teams))
	for _, t := range teams {
		h := t.Slug
		if h == "" {
			h = t.ID
		}
		handles = append(handles, h)
	}
	return strings.Join(handles, ", ")
}

func printTeamsHelp(out *writer) {
	const help = `bp teams — list the teams your Cloud account belongs to.

USAGE
  bp teams

WHAT IT DOES
  reads your memberships from the control plane (GET /v1/me) and prints them as a
  table, with a '*' on the ACTIVE team — the one team-scoped Cloud calls run in.
  Switch the active team with 'bp team use <slug|id>'. Requires 'bp login'.

FLAGS
  -o json      emit one machine-readable JSON object on stdout`
	out.outf("%s", help)
}

func printTeamHelp(out *writer) {
	const help = `bp team — switch the active Cloud team.

USAGE
  bp team use <slug|id>

WHAT IT DOES
  switches the ACTIVE team your Cloud commands run in and persists it to your
  config. The <slug|id> is resolved against your memberships (see 'bp teams'); a
  team you are not a member of is refused. The active team scopes team-aware calls
  such as 'bp instance credentials <id>'. Requires 'bp login'.

NOTE
  The team context rides the X-Barkpark-Team header, honoured for SESSION-token
  auth (the 'bp login' device flow). A personal access token (PAT) is hard-bound
  to its own team and IGNORES the switch — use 'bp login' for cross-team work.`
	out.outf("%s", help)
}
