package cli

// cloud_members.go is `bp cloud members` — the CLI twin of the console's Members
// panel (epic charter C10/OC5/OC8). It lists your team's seats + roles and the
// pending invitations, off GET /v1/teams/:id/members + GET /v1/teams/:id/
// invitations, authenticated with the CLOUD session token — killing the last
// curl-only surface in the terminal too ("one product, two surfaces", parent
// D36).
//
// Honest degradation, deliberately (D25/D51):
//   - the members roster is member-gated, so any member of the team sees it;
//   - the pending-invitations list is ADMIN-gated — a plain member gets a 403,
//     which degrades to one honest note ("visible to admins only") rather than
//     failing the whole view; the seats you CAN see still render;
//   - `-o json` emits the two arrays VERBATIM under {members, invitations}
//     (invitations:null when you may not see them), so a script reads the same
//     contract bytes the control plane serves.
//
// The team is the one your session is bound to (config CloudTeam, written by
// `bp login`); an optional positional overrides it.

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
	"github.com/mattn/go-runewidth"
)

// runCloudMembers is `bp cloud members [team-id]`: resolve the team (session
// default or an explicit id), list its seats + pending invitations, and render
// them. Requires `bp login`.
func runCloudMembers(out *writer, g globals, args []string) int {
	// -h/--help anywhere in the tail prints help (the cloud-webhook/verify
	// convention).
	for _, a := range args {
		if a == "-h" || a == "--help" {
			printCloudMembersHelp(out)
			return exitOK
		}
	}
	if g.help || (len(args) > 0 && args[0] == "help") {
		printCloudMembersHelp(out)
		return exitOK
	}

	const usage = "bp cloud members [team-id]"
	a, err := parseHzArgs(args, nil, nil, usage)
	if err != nil {
		return useError(out, "usage", err.Error(), exitUsage)
	}
	if len(a.pos) > 1 {
		return useError(out, "usage", fmt.Sprintf("want at most one team id (usage: %s)", usage), exitUsage)
	}

	cfg, cerr := LoadConfig()
	if cerr != nil {
		return useError(out, "failed", "read config: "+cerr.Error(), exitGeneric)
	}
	if !cfg.HasCloudToken() {
		return useError(out, "auth", "not logged in — run `bp login` to manage your team", exitAuth)
	}

	teamID := strings.TrimSpace(cfg.CloudTeam)
	if len(a.pos) == 1 {
		teamID = strings.TrimSpace(a.pos[0])
	}
	if teamID == "" {
		return useError(out, "failed",
			"no team on your session — run `bp login` again, or pass a team id (`bp cloud members <team-id>`)",
			exitGeneric)
	}

	client := cfg.CloudClient()

	members, merr := client.TeamMembers(cloudCtx(), teamID)
	if merr != nil {
		return membersFail(out, teamID, merr)
	}

	// Pending invitations are ADMIN-gated: a plain member's 403 is expected and
	// degrades to a note, NOT a failure — the seats already loaded are the point.
	// Any OTHER error (transport, an unexpected code) also degrades to a note so
	// the roster still renders honestly; the note names what could not be read.
	invitations, ierr := client.TeamInvitations(cloudCtx(), teamID)

	if out.output == "json" || out.output == "yaml" {
		// The machine path re-emits the control-plane BYTES (D4), so a parse
		// failure of OUR row structs does not corrupt it — it stays exit 0.
		emitMembersRaw(out, members, invitations, ierr)
		return exitOK
	}
	renderMembersResult(out, teamID, members, invitations, ierr)
	if members.DecodeErr != nil {
		// The human table is built from the PARSED rows, and they do not describe
		// what the server sent. Refuse rather than let "(no members)" or a
		// dashed-out cell pass for a measured roster.
		return exitGeneric
	}
	return exitOK
}

// membersFail maps a refused members read onto the unified `bp:` error seam. The
// team-scoped 404 (a non-member, or no such team — the same, no existence leak)
// is the one contract refusal; anything else routes through cloudFail.
func membersFail(out *writer, teamID string, err error) int {
	var re *cloudclient.CloudRouteError
	if errors.As(err, &re) && re.Code == "not_found" {
		return useError(out, "not_found",
			fmt.Sprintf("no team %q — you are not a member, or it does not exist", teamID),
			exitNotFound)
	}
	return cloudFail(out, "list members", err)
}

// emitMembersRaw writes the two arrays for a machine consumer, combined under
// {members, invitations}. Each array is the control-plane BYTES verbatim (D4) —
// key order and all — so the CLI never becomes a second, drifting definition of
// the contract. When invitations could not be read (admin-gated 403, or a
// transport error) the value is JSON null, so a script sees the honest absence
// rather than an empty list posing as "no invitations".
func emitMembersRaw(out *writer, m cloudclient.MembersResult, inv cloudclient.InvitationsResult, invErr error) {
	membersRaw := rawArrayOr(m.Raw)
	invRaw := "null"
	if invErr == nil {
		invRaw = rawArrayOr(inv.Raw)
	}
	combined := fmt.Sprintf(`{"members":%s,"invitations":%s}`, membersRaw, invRaw)
	switch out.output {
	case "json":
		fmt.Fprintln(out.stdout, combined)
	case "yaml":
		var v any
		if json.Unmarshal([]byte(combined), &v) == nil {
			out.renderYAML(v)
		}
	}
}

// rawArrayOr returns the raw JSON array bytes, or "[]" when the envelope omitted
// the key (a well-formed empty result), so the combined document is always valid
// JSON.
func rawArrayOr(raw json.RawMessage) string {
	s := strings.TrimSpace(string(raw))
	if s == "" || s == "null" {
		return "[]"
	}
	return s
}

// renderMembersResult prints the human view: the seat roster, then the pending
// invitations (or the honest note when they could not be read).
func renderMembersResult(out *writer, teamID string, m cloudclient.MembersResult, inv cloudclient.InvitationsResult, invErr error) {
	out.outf("Members of team %s", sanitizeCell(teamID))
	out.outf("")

	switch {
	case m.DecodeErr != nil:
		// A refused/unreadable roster must never be byte-identical to an empty
		// one. Say what could not be read and point at the verbatim bytes, which
		// `-o json` still serves correctly.
		out.outf("Could not read the member roster: %s", sanitizeCell(m.DecodeErr.Error()))
		out.outf("The seat count below is NOT the roster — re-read with '-o json' for the raw contract bytes.")
	case len(m.Members) == 0:
		out.outf("(no members)")
	default:
		renderMemberTable(out, m.Members)
	}

	out.outf("")
	switch {
	case invErr == nil && inv.DecodeErr != nil:
		// Same rule as the roster: an unparseable list is not "none pending".
		out.outf("Could not read pending invitations: %s", sanitizeCell(inv.DecodeErr.Error()))
	case invErr == nil:
		if len(inv.Invitations) == 0 {
			out.outf("No pending invitations.")
		} else {
			out.outf("Pending invitations")
			renderInvitationTable(out, inv.Invitations)
		}
	case isForbidden(invErr):
		// Admin-gated: the operator is a member, not an admin. Honest note, not a
		// failure (D25 — the seats they can see already rendered).
		out.outf("Pending invitations are visible to team admins only.")
	default:
		// Any other read failure degrades to a note naming what went quiet, so the
		// roster still stands. Never a hang, never a swallowed error.
		out.outf("Could not read pending invitations: %s", sanitizeCell(invErr.Error()))
	}
}

// renderMemberTable prints the seat roster as an aligned table. Roles are not
// statusRole tokens, so no cell is painted — the columns are the plain truth the
// operator manages.
func renderMemberTable(out *writer, members []cloudclient.TeamMember) {
	headers := []string{"EMAIL", "ROLE", "JOINED", "USER ID"}
	rows := make([][]string, 0, len(members))
	for _, mem := range members {
		rows = append(rows, []string{
			memberCell(mem.Email),
			memberCell(mem.Role),
			memberCell(mem.JoinedAt),
			memberCell(mem.UserID),
		})
	}
	renderPlainTable(out, headers, rows)
}

// renderInvitationTable prints the pending invitations as an aligned table.
func renderInvitationTable(out *writer, invitations []cloudclient.TeamInvitation) {
	headers := []string{"EMAIL", "ROLE", "EXPIRES", "INVITED"}
	rows := make([][]string, 0, len(invitations))
	for _, inv := range invitations {
		rows = append(rows, []string{
			memberCell(inv.Email),
			memberCell(inv.Role),
			memberCell(inv.ExpiresAt),
			memberCell(inv.InsertedAt),
		})
	}
	renderPlainTable(out, headers, rows)
}

// renderPlainTable prints an aligned upper-header table with no cell painting —
// the members/invitations rows carry no status tokens. Widths are measured in
// display cells (runewidth), matching the other cloud tables.
func renderPlainTable(out *writer, headers []string, rows [][]string) {
	widths := make([]int, len(headers))
	for i, h := range headers {
		widths[i] = runewidth.StringWidth(h)
	}
	for _, r := range rows {
		for i := range headers {
			if i < len(r) {
				if n := runewidth.StringWidth(r[i]); n > widths[i] {
					widths[i] = n
				}
			}
		}
	}
	out.outf("%s", joinCols(headers, widths))
	for _, r := range rows {
		out.outf("%s", joinCols(r, widths))
	}
}

// memberCell renders a value for a table cell, dashing out empties so columns
// stay scannable.
func memberCell(s string) string {
	if strings.TrimSpace(s) == "" {
		return "—"
	}
	return sanitizeCell(s)
}

// isForbidden reports whether err is the admin-gated 403 refusal.
func isForbidden(err error) bool {
	var re *cloudclient.CloudRouteError
	return errors.As(err, &re) && re.Code == "forbidden"
}

// printCloudMembersHelp writes `bp cloud members` usage.
func printCloudMembersHelp(out *writer) {
	const help = `bp cloud members — your team's seats + pending invitations in the terminal.

USAGE
  bp cloud members [team-id] [-o json|yaml]

WHAT IT SHOWS
  the console's Members panel: every seat (email · role · joined) and the
  pending invitations (email · role · expires). The team is the one your session
  is bound to; pass a team id to override it. Needs 'bp login'.

  Pending invitations are admin-only — as a plain member you still see the
  roster, with an honest note where the invitations would be.

OUTPUT
  two tables (members, then pending invitations).
  -o json    the two arrays verbatim: {members:[…], invitations:[…]}
             (invitations:null when you may not see them)`
	out.outf("%s", help)
}
