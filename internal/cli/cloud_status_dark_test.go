package cli

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/FRIKKern/barkpark/internal/cloudclient"
)

// The package's status fixtures stamp `last_seen_at` with the `seen` const and
// mean it as "a fresh beat". Pin the beat clock one minute after it so every
// existing fixture reads LIVE, as its author meant; the tests below move the
// clock themselves when they need a dark box.
func init() {
	t, err := time.Parse(time.RFC3339, seen)
	if err != nil {
		panic(err)
	}
	darkNow = func() time.Time { return t.Add(time.Minute) }
}

func withDarkNow(t *testing.T, now time.Time) {
	t.Helper()
	prev := darkNow
	darkNow = func() time.Time { return now }
	t.Cleanup(func() { darkNow = prev })
}

func mustTime(t *testing.T, s string) time.Time {
	t.Helper()
	v, err := time.Parse(time.RFC3339, s)
	if err != nil {
		t.Fatal(err)
	}
	return v
}

// muscle1 is the live registry row as the plane served it on 2026-09-25:
// removal_failed, offline/unknown, NO last_seen_at, registered 2026-07-26.
func muscle1() cloudclient.Barkpark {
	return cloudclient.Barkpark{
		ID: "8974b239-6dcf-45f1-b1ff-479bc023291b", Name: "muscle-1", Host: "46.224.19.120",
		URL: "https://muscle-1.barkpark.cloud", HealthStatus: "unknown", AgentStatus: "offline",
		DeprovisionStatus: "failed", DeprovisionError: "deprovision 46.224.19.120: refusing to delete",
		InsertedAt: "2026-07-26T13:47:46.176707Z",
	}
}

// c0: a dark box's row names HOW LONG — measured when a last beat exists, a
// labelled lower bound when none does — on the table AND in -o json.
func TestDarkDurationIsNamedOnTheRow(t *testing.T) {
	now := mustTime(t, "2026-09-25T09:05:00Z")
	withDarkNow(t, now)

	// (a) A box whose last beat is 19h01m old — the filing's shape.
	silent := cloudclient.Barkpark{ID: "g", Name: "gyldendal", Host: "10.0.0.2",
		HealthStatus: "unknown", AgentStatus: "offline",
		LastSeenAt: "2026-09-24T14:04:00Z", InsertedAt: "2026-07-09T16:38:01Z"}
	d := attentionDetail(silent, attentionStatus(silent))
	if !strings.HasPrefix(d, "dark 19h01m — last beat 2026-09-24T14:04Z") {
		t.Fatalf("stale-beat detail = %q, want it to LEAD with the dark duration", d)
	}
	beat := beatRow(silent)
	if beat["state"] != "dark" || beat["dark_for_seconds"] != int64(19*3600+60) {
		t.Fatalf("stale-beat json = %v, want state dark, dark_for_seconds 68460", beat)
	}

	// (b) A two-minute-old beat is LIVE — the two must not render alike.
	fresh := silent
	fresh.LastSeenAt = now.Add(-2 * time.Minute).Format(time.RFC3339)
	if m := darkMarker(fresh, "ok"); m != "" {
		t.Fatalf("a 2-minute-old beat is inside the plane's 180s window, must not read dark: %q", m)
	}
	if b := beatRow(fresh); b["state"] != "live" || b["dark_for_seconds"] != nil {
		t.Fatalf("fresh json = %v, want state live and no duration key", b)
	}

	// (b2) CLIENT CLOCK GUARD: a box the plane still calls online is not
	// painted dark by a 10-minute gap (a fast laptop clock, or a stale read) —
	// but past the margin it is, whatever the plane says.
	onlineGap := silent
	onlineGap.AgentStatus = "online"
	onlineGap.LastSeenAt = now.Add(-10 * time.Minute).Format(time.RFC3339)
	if m := darkMarker(onlineGap, "ok"); m != "" {
		t.Fatalf("plane says online, beat 10m old — inside the clock margin, must not read dark: %q", m)
	}
	onlineGap.LastSeenAt = now.Add(-2 * time.Hour).Format(time.RFC3339)
	if m := darkMarker(onlineGap, "ok"); !strings.HasPrefix(m, "dark 2h00m") {
		t.Fatalf("plane says online, beat 2h old — past the margin, must read dark: %q", m)
	}

	// (c) muscle-1: no beat on record. A LOWER BOUND from registration, marked
	// ≥, never a zero — and it leads the removal_failed reason.
	m := muscle1()
	st := attentionStatus(m)
	if st != "removal_failed" {
		t.Fatalf("muscle-1 status = %q, want removal_failed (the rung must not move)", st)
	}
	d = attentionDetail(m, st)
	if !strings.HasPrefix(d, "dark ≥60d19h — no beat on record since it was registered 2026-07-26T13:47Z · deprovision") {
		t.Fatalf("muscle-1 detail = %q", d)
	}
	beat = beatRow(m)
	if beat["state"] != "never" {
		t.Fatalf("muscle-1 beat state = %v, want never", beat["state"])
	}
	if _, has := beat["dark_for_seconds"]; has {
		t.Fatalf("a never-beaten box must carry NO measured duration: %v", beat)
	}
	if beat["dark_at_least_seconds"] == nil || beat["dark_at_least_seconds"].(int64) <= 0 {
		t.Fatalf("muscle-1 must carry a positive lower bound: %v", beat)
	}

	// (d) Never beaten AND no registration time: no number at all, not 0.
	m.InsertedAt = ""
	d = attentionDetail(m, attentionStatus(m))
	if !strings.Contains(d, "no beat on record (registration time unknown, so no duration)") {
		t.Fatalf("unknown-registration detail = %q", d)
	}
	if b := beatRow(m); b["dark_at_least_seconds"] != nil || b["dark_for_seconds"] != nil {
		t.Fatalf("no number behind it, so no duration key: %v", b)
	}

	// (e) Registered inside the stale window: still coming up, not dark.
	young := muscle1()
	young.DeprovisionStatus = ""
	young.InsertedAt = now.Add(-time.Minute).Format(time.RFC3339)
	if m := darkMarker(young, "unreported"); m != "" {
		t.Fatalf("a one-minute-old registration is pending, not dark: %q", m)
	}

	// (f) An unparseable stamp is UNMEASURED, never live.
	bad := silent
	bad.LastSeenAt = "yesterday"
	if b := beatRow(bad); b["state"] != "unmeasured" {
		t.Fatalf("unparseable stamp state = %v, want unmeasured", b["state"])
	}
}

func TestDarkDurationFormat(t *testing.T) {
	for _, c := range []struct {
		d    time.Duration
		want string
	}{
		{4 * time.Minute, "4m"},
		{19*time.Hour + 6*time.Minute, "19h06m"},
		{49*24*time.Hour + 3*time.Hour, "49d03h"},
	} {
		if got := darkDuration(c.d); got != c.want {
			t.Errorf("darkDuration(%v) = %q, want %q", c.d, got, c.want)
		}
	}
}

// c1: a planted duplicate is found, by the key that makes it the same box, and
// a name collision is reported as a DIFFERENT sentence. The live fleet's shape
// (gyl vs Gyldendal, distinct hosts) must report nothing.
func TestDuplicateRegistryRowsDetected(t *testing.T) {
	withDarkNow(t, mustTime(t, "2026-09-25T09:05:00Z"))
	live := []cloudclient.Barkpark{
		{ID: "a1", Name: "Gyldendal", Host: "5.75.169.183", URL: "https://gyldendal.barkpark.cloud"},
		{ID: "b1", Name: "gyl", Host: "46.225.61.223", URL: "https://gyl.barkpark.cloud"},
		muscle1(),
	}
	if rep := findDuplicateRows(live); len(rep.Groups) != 0 || rep.Checked != 3 {
		t.Fatalf("today's fleet shape has no duplicate, got %+v", rep)
	}

	// Plant the filing's row: lowercase 'gyldendal' on the SAME box.
	planted := append(append([]cloudclient.Barkpark{}, live...), cloudclient.Barkpark{
		ID: "z9", Name: "gyldendal", Host: "5.75.169.183 ", URL: "https://Gyldendal.barkpark.cloud./",
		AgentStatus: "offline", LastSeenAt: "2026-08-06T08:06:00Z",
	})
	rep := findDuplicateRows(planted)
	keys := map[string]int{}
	for _, g := range rep.Groups {
		keys[g.Key] = len(g.Rows)
	}
	if keys["host"] != 2 || keys["url"] != 2 || keys["name"] != 2 || len(rep.Groups) != 3 {
		t.Fatalf("planted duplicate: groups = %+v, want host/url/name each with 2 rows", rep.Groups)
	}

	// A name-only collision on two different boxes is NOT a same-box duplicate.
	nameOnly := append(append([]cloudclient.Barkpark{}, live...), cloudclient.Barkpark{
		ID: "y8", Name: "GYL", Host: "9.9.9.9", URL: "https://gyl-2.barkpark.cloud"})
	rep = findDuplicateRows(nameOnly)
	if len(rep.Groups) != 1 || rep.Groups[0].Key != "name" {
		t.Fatalf("name-only collision groups = %+v", rep.Groups)
	}
	if js := duplicatesJSON(rep); js["groups"].([]any)[0].(map[string]any)["same_box"] != false {
		t.Fatalf("a name collision must say same_box false: %v", js)
	}

	// Empty hosts (boxes still provisioning) never pair on "".
	if rep := findDuplicateRows([]cloudclient.Barkpark{{ID: "p1", Name: "a"}, {ID: "p2", Name: "b"}}); len(rep.Groups) != 0 {
		t.Fatalf("two host-less rows paired on the empty key: %+v", rep.Groups)
	}
}

// Both renderings, end to end through runCloudStatus: the table prints the
// dark duration and the duplicate section; -o json carries beat + duplicates.
func TestCloudStatusRendersDarkAndDuplicates(t *testing.T) {
	withDarkNow(t, mustTime(t, "2026-09-25T09:05:00Z"))
	body := `{"barkparks":[
		{"id":"8974b239-6dcf-45f1-b1ff-479bc023291b","name":"muscle-1","host":"46.224.19.120","url":"https://muscle-1.barkpark.cloud","health_status":"unknown","agent_status":"offline","deprovision_status":"failed","deprovision_error":"refusing to delete","inserted_at":"2026-07-26T13:47:46.176707Z","queued_deploy_age_seconds":null},
		{"id":"a1","name":"Gyldendal","host":"5.75.169.183","url":"https://gyldendal.barkpark.cloud","health_status":"up","agent_status":"online","last_seen_at":"2026-09-25T09:04:30Z","queued_deploy_age_seconds":null},
		{"id":"z9","name":"gyldendal","host":"5.75.169.183","url":"https://gyldendal-old.barkpark.cloud","health_status":"unknown","agent_status":"offline","last_seen_at":"2026-09-24T14:04:00Z","queued_deploy_age_seconds":null}
	]}`
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/v1/deploy-ledger/census":
			_, _ = io.WriteString(w, `{"volume":0,"failed":0,"failure_rate":{"sample":0,"pct":null,"numerator":0,"min_sample":200,"refused":true,"reason":"sample 0 below min_sample 200"},"classes":[],"not_attempted":[],"sites":[],"min_sample":200}`)
		case "/v1/sites":
			_, _ = io.WriteString(w, `{"sites":[]}`)
		default:
			_, _ = io.WriteString(w, body)
		}
	}))
	defer srv.Close()
	seedCloudLogin(t, srv.URL)

	table, _, code := runCloudCapture(t, false, func(out *writer) int { out.output = "table"; return runCloudStatus(out, globals{}, nil) })
	if code != exitOK {
		t.Fatalf("exit %d:\n%s", code, table)
	}
	for _, want := range []string{
		"dark ≥60d19h — no beat on record since it was registered 2026-07-26T13:47Z",
		"dark 19h01m — last beat 2026-09-24T14:04Z",
		"DUPLICATE REGISTRY ROWS (2) — 3 row(s) checked",
		"same box: host 5.75.169.183 — 2 rows:",
		"name collision (case-folded, possibly different boxes): gyldendal — 2 rows:",
	} {
		if !strings.Contains(table, want) {
			t.Errorf("table missing %q:\n%s", want, table)
		}
	}
	t.Logf("table:\n%s", table)

	js, _, code := runCloudCapture(t, true, func(out *writer) int { return runCloudStatus(out, globals{}, nil) })
	if code != exitOK {
		t.Fatalf("exit %d:\n%s", code, js)
	}
	var doc struct {
		Barkparks []struct {
			Name       string         `json:"name"`
			LastSeenAt *string        `json:"last_seen_at"`
			Beat       map[string]any `json:"beat"`
		} `json:"barkparks"`
		Duplicates struct {
			Checked int              `json:"checked"`
			Groups  []map[string]any `json:"groups"`
		} `json:"duplicates"`
	}
	if err := json.Unmarshal([]byte(js), &doc); err != nil {
		t.Fatalf("decode: %v\n%s", err, js)
	}
	got := map[string]map[string]any{}
	for _, b := range doc.Barkparks {
		if b.LastSeenAt == nil {
			t.Errorf("%s: last_seen_at must ALWAYS be present", b.Name)
		}
		got[b.Name] = b.Beat
	}
	if got["muscle-1"]["state"] != "never" || got["muscle-1"]["dark_at_least_seconds"] == nil || got["muscle-1"]["dark_for_seconds"] != nil {
		t.Errorf("muscle-1 beat = %v", got["muscle-1"])
	}
	if got["gyldendal"]["state"] != "dark" || got["gyldendal"]["dark_for_seconds"] != float64(68460) {
		t.Errorf("gyldendal beat = %v", got["gyldendal"])
	}
	if got["Gyldendal"]["state"] != "live" {
		t.Errorf("Gyldendal beat = %v", got["Gyldendal"])
	}
	if doc.Duplicates.Checked != 3 || len(doc.Duplicates.Groups) != 2 {
		t.Errorf("duplicates = %+v", doc.Duplicates)
	}
}
