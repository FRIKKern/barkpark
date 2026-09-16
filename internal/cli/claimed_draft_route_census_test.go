package cli

// claimed_draft_route_census_test.go is the tripwire for THE NEXT DOOR.
//
// task-7b13c4042bb0ab7c exists because the previous two rows each closed ONE
// verb and left the census to the next reader. Four more doors were found the
// hard way, by a human enumerating them. guardClaimedDraftMutation ends that
// for every verb on the mutate route — it reads the RESOLVED REQUEST, so a
// seventh verb there is covered the day it ships, with nothing to notice.
//
// What it cannot cover is a draft-writing verb on a DIFFERENT route, exactly as
// `doc restore-revision` is today. So that case is not left to be noticed
// either: this test enumerates every `writes:true` doc command in the LIVE
// capabilities fixture, derives its route, and refuses any route that is
// neither the choke point nor a named, separately-guarded exception.
//
// THE TRIGGER, stated so it cannot be mistaken for a style check: when this
// test reds, the manifest has grown a doc write on a route no claim-wall guard
// watches. Do ONE of two things — never edit the expectation to make it green:
//
//  1. if the new verb lands draft bytes on `drafts.<id>` of a task, guard it
//     (route it through the mutate choke point, or give it a guard the way
//     claimed_restore_revision_guard.go did) and then add its route below with
//     the guard's name; or
//  2. if it structurally cannot reach the trap, add it below with the reason —
//     the way `doc.unpublish` was excluded BY SHAPE in the row that filed this.

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
	"testing"
)

// liveCapabilitiesFixture is the capabilities document the CLI suite already
// treats as the live roster (internal/cli/dataset_reaches_path_routed_route_test.go
// reads the same file for the same reason): it is a real server's manifest,
// not a hand-written slice, so a command that appears there appeared in
// production.
const liveCapabilitiesFixture = "../manifest/testdata/capabilities-guerrilla-2026-09-04.json"

// accountedDraftWriteRoutes maps every route a `writes:true` doc command may
// resolve to onto the reason it is accounted for. The KEY is method + " " +
// path_template, so a verb RENAME cannot silently open a hole and a new PATH
// cannot pass unremarked.
var accountedDraftWriteRoutes = map[string]string{
	// THE CHOKE POINT. guardClaimedDraftMutation reads the resolved mutation
	// batch on this route and refuses a payload-carrying write onto the
	// `drafts.` twin of a CLAIMED task — whatever verb produced it, including a
	// `doc mutate` batch, including a verb that does not exist yet.
	"POST /v1/data/mutate/:dataset": "guardClaimedDraftMutation (claimed_draft_mutation_guard.go)",

	// THE ONE OFF-ROUTE DOOR. `doc restore-revision` writes the same
	// unpublishable twin through a route of its own, so it carries a guard of
	// its own — the shape this census exists to make visible rather than
	// discovered.
	"POST /v1/data/revision/:dataset/:rev_id/restore": "guardClaimedRestoreRevision (claimed_restore_revision_guard.go)",
}

// capabilitiesRoster is the slice of the capabilities document this census
// reads. The live fixture is the THIN shape (`args`/`flags` entries carry only
// the fields the server bothered to emit), so every field here is optional.
type capabilitiesRoster struct {
	Commands []struct {
		ID     string `json:"id"`
		Noun   string `json:"noun"`
		Verb   string `json:"verb"`
		Writes bool   `json:"writes"`
		HTTP   struct {
			Method       string `json:"method"`
			PathTemplate string `json:"path_template"`
		} `json:"http"`
	} `json:"commands"`
}

// TestEveryDocWriteRouteIsAccountedForByAClaimWallGuard reds when a doc write
// appears on a route no claim-wall guard watches.
//
// CONTROL: the census must actually SEE the roster. A test that read zero rows
// would pass this silently and measure nothing (an absence is never caught by
// inspection), so the row count and the two known routes are asserted first.
func TestEveryDocWriteRouteIsAccountedForByAClaimWallGuard(t *testing.T) {
	raw, err := os.ReadFile(liveCapabilitiesFixture)
	if err != nil {
		t.Fatalf("read %s: %v", liveCapabilitiesFixture, err)
	}
	var roster capabilitiesRoster
	if err := json.Unmarshal(raw, &roster); err != nil {
		t.Fatalf("parse %s: %v", liveCapabilitiesFixture, err)
	}

	routes := map[string][]string{}
	for _, c := range roster.Commands {
		if c.Noun != "doc" || !c.Writes {
			continue
		}
		key := c.HTTP.Method + " " + c.HTTP.PathTemplate
		routes[key] = append(routes[key], c.ID)
	}

	// CONTROL ONE: the roster was read, and it contains doc writes. Without
	// this, a renamed fixture or a changed JSON shape would make the census
	// vacuously green while watching nothing.
	if len(routes) == 0 {
		t.Fatalf("no `writes:true` doc commands found in %s — the census read nothing and is measuring nothing", liveCapabilitiesFixture)
	}
	total := 0
	for _, ids := range routes {
		total += len(ids)
	}
	if total < 6 {
		t.Fatalf("only %d doc write commands found in %s — the live roster had 10 on 2026-09-16; the census is reading the wrong shape", total, liveCapabilitiesFixture)
	}

	// CONTROL TWO: both accounted routes are actually PRESENT in the roster. A
	// stale entry here would be a guard pointed at a route nobody serves, and
	// the census would never say so.
	for route := range accountedDraftWriteRoutes {
		if len(routes[route]) == 0 {
			t.Errorf("accounted route %q carries no doc write in %s — either the route moved (the guard is now pointed at nothing) or this entry is stale", route, liveCapabilitiesFixture)
		}
	}

	var unaccounted []string
	for route, ids := range routes {
		if _, ok := accountedDraftWriteRoutes[route]; ok {
			continue
		}
		sort.Strings(ids)
		unaccounted = append(unaccounted, route+"  ("+strings.Join(ids, ", ")+")")
	}
	if len(unaccounted) > 0 {
		sort.Strings(unaccounted)
		t.Errorf("a doc write reaches a route no claim-wall guard watches:\n  %s\n\n"+
			"This is THE NEXT DOOR. `bp doc patch`, the create family and `bp doc mutate` all mint a\n"+
			"claim-less `drafts.<id>` twin over a CLAIMED published task, and the publish wall then\n"+
			"refuses that draft forever. Do NOT add the route to accountedDraftWriteRoutes to go green.\n"+
			"Either (1) prove the new verb cannot land draft bytes on an existing published task's twin,\n"+
			"and record it with that reason, or (2) guard it — route it through the mutate choke point\n"+
			"(guardClaimedDraftMutation), or give it its own guard calling probePublishedClaim the way\n"+
			"claimed_restore_revision_guard.go does — and then record it with the guard's name.",
			strings.Join(unaccounted, "\n  "))
	}
}
