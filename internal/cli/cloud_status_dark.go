package cli

// cloud_status_dark.go — two things `bp cloud status` could not say
// (dr-bl-w9-muscle-1-is-dark-and-nothing-says-so):
//
//  1. HOW LONG a box has been dark. The fleet row said `offline` / `unknown`,
//     and a nineteen-hour silence rendered exactly like a two-minute one. The
//     number was never missing from the wire: GET /v1/barkparks has always
//     emitted `last_seen_at` (the agent's last health report, stamped by
//     POST /v1/agent/report) and `inserted_at`, and cloudclient.Barkpark has
//     always decoded both. rankedBarkparkRow simply never projected them — the
//     same projection gap dr-w21-s3 found for git_commit. So this is a CLIENT
//     fix and ships no new wire key.
//
//  2. A DUPLICATE REGISTRY ROW for one box. Nothing in the schema stops it:
//     `barkparks` is unique on (team_id, slug), on url, and on custom_host —
//     never on host. Two rows claiming one IP both render as ordinary rows.
//
// ABSENT IS UNMEASURED, NEVER ZERO. A box with no `last_seen_at` has no beat
// on record; it is rendered as that sentence, with the only honest lower bound
// the plane holds (its registration age — the StalenessWorker moduledoc gives
// the same instruction: "derive a never-reported box's age from inserted_at").
// It is never rendered as "dark 0s", and the JSON never carries a zero for it.

import (
	"fmt"
	"net/url"
	"sort"
	"strings"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// beatStaleAfter mirrors the control plane's @default_health_stale_after_seconds
// (cloud/lib/barkpark_cloud/registry.ex: 180 s, ≈3 agent ticks) — the age at
// which the plane itself counts a heartbeat as missed. A box whose last beat is
// younger than this is live; older is dark. Mirrored rather than invented so
// the CLI and the StalenessWorker call a box dark at the same moment.
const beatStaleAfter = 180 * time.Second

// beatClockMargin guards against the one input this file does not own: the
// CLIENT's clock. Age is `darkNow() - last_seen_at`, and last_seen_at is the
// plane's clock. A laptop five minutes fast would paint every healthy box
// "dark 5m" off the 180 s fence alone — measured, not hypothetical: a replay of
// a ten-minute-old capture of the live fleet read eight beating boxes as
// "dark 10m". So a box the PLANE still calls `online` is only called dark once
// its beat is older than this margin (the plane flips a silent box offline
// within ~2 ticks of the fence, so a real outage crosses to the offline arm
// long before; the margin only catches a team the StalenessWorker does not
// sweep — it requires an active subscription). A box the plane already calls
// offline is dark from the 180 s fence, and the plane's verdict is not
// second-guessed in either direction.
const beatClockMargin = 15 * time.Minute

// darkNow is the clock beat ages are measured against — a package var (the
// statusDeployNow idiom) so a test can pin it.
var darkNow = func() time.Time { return time.Now().UTC() }

// The beat states. Every one is a distinct sentence; none collapses into
// another, and only `dark` carries a measured duration.
const (
	beatLive       = "live"       // last beat within beatStaleAfter (beatClockMargin while the plane says online)
	beatDark       = "dark"       // last beat older than beatStaleAfter — duration MEASURED
	beatNever      = "never"      // a box exists, no beat on record — duration is a LOWER BOUND at most
	beatPending    = "pending"    // no beat yet, registered inside the stale window — still coming up
	beatUnmeasured = "unmeasured" // last_seen_at present but unparseable
	beatNoBox      = "no_box"     // no host: nothing exists that could beat
)

// beatReading is one box's heartbeat age, computed once and rendered twice
// (the DETAIL marker and the `-o json` "beat" object).
type beatReading struct {
	State        string
	LastBeatAt   string // RFC3339 as the plane sent it; "" when none
	RegisteredAt string // inserted_at as the plane sent it; "" when none
	// DarkFor is the MEASURED silence (state dark only).
	DarkFor time.Duration
	// AtLeast is the registration age of a never-beaten box — a LOWER BOUND on
	// its silence, not a measurement of it. AtLeastKnown is false when the plane
	// sent no parseable inserted_at, and then no number is printed at all.
	AtLeast      time.Duration
	AtLeastKnown bool
}

func parseStamp(s string) (time.Time, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false
	}
	t, err := time.Parse(time.RFC3339, s)
	if err != nil {
		return time.Time{}, false
	}
	return t, true
}

// readBeat classifies a box's heartbeat age off the two wire stamps.
func readBeat(b cloudclient.Barkpark, now time.Time) beatReading {
	r := beatReading{
		LastBeatAt:   strings.TrimSpace(b.LastSeenAt),
		RegisteredAt: strings.TrimSpace(b.InsertedAt),
	}
	if strings.TrimSpace(b.Host) == "" {
		r.State = beatNoBox
		return r
	}
	if r.LastBeatAt != "" {
		seen, ok := parseStamp(r.LastBeatAt)
		if !ok {
			r.State = beatUnmeasured
			return r
		}
		age := now.Sub(seen)
		planeSaysOnline := strings.TrimSpace(b.AgentStatus) == "online"
		if age <= beatStaleAfter || (planeSaysOnline && age <= beatClockMargin) {
			r.State = beatLive
			return r
		}
		r.State = beatDark
		r.DarkFor = age
		return r
	}
	// No beat on record. The registration age is the only honest bound.
	if reg, ok := parseStamp(r.RegisteredAt); ok {
		r.AtLeast = now.Sub(reg)
		r.AtLeastKnown = r.AtLeast >= 0
		if r.AtLeastKnown && r.AtLeast <= beatStaleAfter {
			r.State = beatPending
			return r
		}
	}
	r.State = beatNever
	return r
}

// darkDuration renders a silence the way an operator says it: "4m", "19h06m",
// "49d03h". Days are spelled out past 48 hours because "1177h" is not a number
// anyone reads at a glance.
func darkDuration(d time.Duration) string {
	if d < 0 {
		return "?"
	}
	total := int(d.Seconds())
	switch {
	case total < 3600:
		return fmt.Sprintf("%dm", total/60)
	case total < 48*3600:
		return fmt.Sprintf("%dh%02dm", total/3600, (total%3600)/60)
	default:
		return fmt.Sprintf("%dd%02dh", total/86400, (total%86400)/3600)
	}
}

// shortStamp trims an RFC3339 stamp to the minute, UTC, for a table cell.
func shortStamp(s string) string {
	if t, ok := parseStamp(s); ok {
		return t.UTC().Format("2006-01-02T15:04Z")
	}
	return sanitizeCell(s)
}

// darkMarker is the DETAIL sentence for a box that is not beating. It rides
// on ANY row, whatever rung the row took — muscle-1 sits at removal_failed,
// and the rung word says nothing about how long the box has been silent.
// Live, pending and box-less rows print nothing.
//
// On an `unreported` row with no registration time the marker would only
// repeat the rung word ("never reported") with no number, so it stays silent
// there; with a registration time it adds the one thing the rung cannot say.
func darkMarker(b cloudclient.Barkpark, status string) string {
	r := readBeat(b, darkNow())
	switch r.State {
	case beatDark:
		return "dark " + darkDuration(r.DarkFor) + " — last beat " + shortStamp(r.LastBeatAt)
	case beatNever:
		if r.AtLeastKnown {
			return "dark ≥" + darkDuration(r.AtLeast) + " — no beat on record since it was registered " + shortStamp(r.RegisteredAt)
		}
		if status == "unreported" {
			return ""
		}
		return "dark — no beat on record (registration time unknown, so no duration)"
	case beatUnmeasured:
		return "beat age UNMEASURED — last_seen_at unreadable: " + sanitizeCell(r.LastBeatAt)
	}
	return ""
}

// beatRow is the `-o json` form. Keys are TRI-STATE by the rankedBarkparkRow
// rule: a duration key appears only when there is a number behind it, so a
// script can never read an absent measurement as 0.
func beatRow(b cloudclient.Barkpark) map[string]any {
	r := readBeat(b, darkNow())
	row := map[string]any{"state": r.State}
	if r.LastBeatAt != "" {
		row["last_beat_at"] = r.LastBeatAt
	}
	if r.RegisteredAt != "" {
		row["registered_at"] = r.RegisteredAt
	}
	switch r.State {
	case beatDark:
		row["dark_for_seconds"] = int64(r.DarkFor.Seconds())
	case beatNever:
		if r.AtLeastKnown {
			row["dark_at_least_seconds"] = int64(r.AtLeast.Seconds())
		}
	}
	return row
}

// --- duplicate registry rows ---------------------------------------------------
//
// THE KEY. A registry row is a claim on a box; two rows are the same box when
// they claim the same MACHINE or the same PUBLIC ADDRESS:
//
//   - host — the box's IP. The schema has no unique index on it, so nothing
//     refuses a second row; this is the definitive "same box" key.
//   - url hostname, case-folded, trailing dot dropped — the index on `url` is
//     on the RAW column, and the model's own normalize_url comment enumerates
//     spellings it still admits for one hostname.
//
// NAME IS NOT A BOX KEY, and is reported separately as a NAME COLLISION. The
// filing's case — a lowercase `gyldendal` beside `Gyldendal` — is two names a
// human cannot tell apart, but two rows can share a name on two boxes (today
// `gyl` and `Gyldendal` differ by host, and so would `gyldendal` if it held its
// own IP). A name collision asks "which one do you mean?", a host collision
// says "one box, two rows"; they are different sentences.
//
// SCOPE: the rows GET /v1/barkparks returned — the caller's team. A duplicate
// split across two teams is not visible from here.

type dupGroup struct {
	Key   string // "host" | "url" | "name"
	Value string
	Rows  []cloudclient.Barkpark
}

type dupReport struct {
	Checked int
	Groups  []dupGroup
}

func urlHostKey(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return ""
	}
	return strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
}

func findDuplicateRows(list []cloudclient.Barkpark) dupReport {
	keys := []struct {
		name string
		of   func(cloudclient.Barkpark) string
	}{
		{"host", func(b cloudclient.Barkpark) string { return strings.ToLower(strings.TrimSpace(b.Host)) }},
		{"url", func(b cloudclient.Barkpark) string { return urlHostKey(b.URL) }},
		{"name", func(b cloudclient.Barkpark) string { return strings.ToLower(strings.TrimSpace(b.Name)) }},
	}
	rep := dupReport{Checked: len(list)}
	for _, k := range keys {
		by := map[string][]cloudclient.Barkpark{}
		for _, b := range list {
			v := k.of(b)
			if v == "" { // an empty key is "unknown", never a shared value
				continue
			}
			by[v] = append(by[v], b)
		}
		vals := make([]string, 0, len(by))
		for v, rows := range by {
			if len(rows) > 1 {
				vals = append(vals, v)
			}
		}
		sort.Strings(vals)
		for _, v := range vals {
			rows := by[v]
			sort.SliceStable(rows, func(i, j int) bool { return rows[i].ID < rows[j].ID })
			rep.Groups = append(rep.Groups, dupGroup{Key: k.name, Value: v, Rows: rows})
		}
	}
	return rep
}

func dupKeyPhrase(key string) string {
	switch key {
	case "host":
		return "same box: host"
	case "url":
		return "same address: url host"
	default:
		return "name collision (case-folded, possibly different boxes):"
	}
}

func dupRowLabel(b cloudclient.Barkpark) string {
	beat := "live"
	if m := darkMarker(b, ""); m != "" {
		beat = m
	}
	id := b.ID
	if len(id) > 8 {
		id = id[:8]
	}
	return fmt.Sprintf("%s (id %s, host %s, %s)", sanitizeCell(b.Name), id, statusDash(b.Host), beat)
}

// renderDuplicates prints the section. It ALWAYS prints a line — the
// detector's silence would be indistinguishable from the detector not having
// run, which is the exact absence this row exists to end.
func renderDuplicates(out *writer, rep dupReport) {
	out.outf("")
	if len(rep.Groups) == 0 {
		out.outf("DUPLICATE REGISTRY ROWS: none — %d row(s) checked by host, url host and case-folded name", rep.Checked)
		return
	}
	out.outf("DUPLICATE REGISTRY ROWS (%d) — %d row(s) checked by host, url host and case-folded name", len(rep.Groups), rep.Checked)
	for _, g := range rep.Groups {
		out.outf("  %s %s — %d rows:", dupKeyPhrase(g.Key), sanitizeCell(g.Value), len(g.Rows))
		for _, b := range g.Rows {
			out.outf("    %s", dupRowLabel(b))
		}
	}
}

func duplicatesJSON(rep dupReport) map[string]any {
	groups := make([]any, 0, len(rep.Groups))
	for _, g := range rep.Groups {
		rows := make([]any, 0, len(g.Rows))
		for _, b := range g.Rows {
			rows = append(rows, map[string]any{
				"id":   b.ID,
				"name": b.Name,
				"host": b.Host,
				"url":  b.URL,
				"beat": beatRow(b),
			})
		}
		groups = append(groups, map[string]any{
			"key":       g.Key,
			"same_box":  g.Key != "name",
			"value":     g.Value,
			"row_count": len(g.Rows),
			"rows":      rows,
		})
	}
	return map[string]any{
		"checked": rep.Checked,
		"keys":    []string{"host", "url", "name"},
		"scope":   "the rows GET /v1/barkparks returned (this team)",
		"groups":  groups,
	}
}
