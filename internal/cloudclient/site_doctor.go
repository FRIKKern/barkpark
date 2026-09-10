package cloudclient

// site_doctor.go is the Go half of ssw8-site-doctor: the decode for
// GET /v1/sites/:id/doctor, the control plane's per-substrate report on
// everything a spawned site occupies that it can genuinely reach.
//
// THE WHOLE POINT OF THE TYPE IS THE THIRD VALUE. The server's report is
// three-valued per substrate — present / absent / unknown — plus
// not_applicable for a substrate this KIND of site legitimately does not have
// (a node site has no `current` symlink; it runs the slot model). A read that
// could not be PERFORMED is `unknown` WITH ITS REASON, never `absent`: absent
// is a claim about the world, unknown is a claim about the doctor. This client
// therefore decodes State as the server's own string and NEVER folds the four
// into a bool — a bool is the exact collapse the route exists to prevent, and
// the CLI receipt renders straight off these strings.

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"time"
)

// The four substrate states, as the control plane spells them
// (BarkparkCloud.Sites.Doctor's @present/@absent/@unknown/@not_applicable).
// They are constants so the renderer branches on a named value rather than on a
// literal typo'd in one place — but the renderer is deliberately TOTAL over
// them: a state this client has never heard of is shown verbatim rather than
// mapped to anything, because inventing a mapping for an unknown word is how a
// receipt starts claiming more than the server said.
const (
	SiteDoctorPresent       = "present"
	SiteDoctorAbsent        = "absent"
	SiteDoctorUnknown       = "unknown"
	SiteDoctorNotApplicable = "not_applicable"
)

// SiteDoctorSubstrate is ONE substrate row. Repair is the EXACT repair verb for
// an absent/mismatched row, or a sentence that begins "NO repair verb exists —"
// when the codebase genuinely cannot perform one; the control plane never
// promises a repair it cannot do, and this client never invents one when the
// field is empty.
type SiteDoctorSubstrate struct {
	Key    string `json:"key"`
	State  string `json:"state"`
	Detail string `json:"detail"`
	Repair string `json:"repair"`
}

// SiteDoctorSite is the identity half of the report: which row was examined.
// Framework and Instance are nullable on the wire (an unprovisioned instance
// carries no slug) and decode to "" — the renderer says so rather than printing
// an empty column.
type SiteDoctorSite struct {
	ID        string `json:"id"`
	Slug      string `json:"slug"`
	Name      string `json:"name"`
	Kind      string `json:"kind"`
	Framework string `json:"framework"`
	Instance  string `json:"instance"`
}

// SiteDoctorReport is a COMPLETED doctor run. OK is the VERDICT — true when
// nothing is absent — and it is deliberately NOT sunk by an unknown: an unknown
// is an abstention, not a failure, and a doctor that cried wolf over every box
// that was briefly down would be ignored. UnknownCount and Unreadable are what
// stop a green report being mistaken for a fully-measured one, so the receipt
// prints them beside the verdict rather than under a -v flag.
//
// Raw is the envelope BYTES verbatim so `-o json` re-emits the server's contract
// without this client reshaping it (the verify-envelope idiom already used by
// DomainStatusResult).
type SiteDoctorReport struct {
	Raw          []byte                `json:"-"`
	OK           bool                  `json:"ok"`
	CheckedAt    string                `json:"checked_at"`
	Site         SiteDoctorSite        `json:"site"`
	Substrates   []SiteDoctorSubstrate `json:"substrates"`
	AbsentCount  int                   `json:"absent_count"`
	UnknownCount int                   `json:"unknown_count"`
	Unreadable   []string              `json:"unreadable"`
}

// SiteDoctorTimeout is the wall-clock cap for a SiteDoctor call. The route is
// SYNCHRONOUS and it goes out over the wire twice on the box's behalf — the read
// token's liveness probe (Registry.relay_as/4 against the instance) and an
// actual FETCH of the live URL — so it needs headroom past the DefaultTimeout
// that fits a quick control-plane read. Same reasoning, and the same number, as
// DomainStatusTimeout: the half-spawned site this verb exists to diagnose is
// exactly the one whose box is slow to answer, and surfacing that as a Go
// transport error instead of the honest `unknown` rows the server was about to
// send would defeat the verb.
const SiteDoctorTimeout = 90 * time.Second

// SiteDoctor reads GET /v1/sites/:id/doctor — team-scoped and READ-ONLY; the
// route writes nothing and this call has no body. A 200 is a completed run, and
// the verdict is in the report (read OK / AbsentCount), never in the absence of
// a Go error: a site with six absent substrates arrives here as a successful
// call carrying six absent rows. A wrong-team or unknown id answers 404, which
// surfaces through cloudError like every other refusal.
func (c *Client) SiteDoctor(ctx context.Context, id string) (SiteDoctorReport, error) {
	// Widen only the lazily-built fallback client, and only for this call — an
	// injected HTTP client (tests) is honored untouched. Same shape as
	// DomainStatus above it.
	dc := *c
	if dc.HTTP == nil {
		dc.HTTP = &http.Client{Timeout: SiteDoctorTimeout}
	}
	status, raw, err := dc.do(ctx, "GET", "/v1/sites/"+esc(id)+"/doctor", true, nil)
	if err != nil {
		return SiteDoctorReport{}, err
	}
	if !ok(status) {
		return SiteDoctorReport{}, cloudError(status, raw)
	}
	res := SiteDoctorReport{Raw: raw}
	if err := json.Unmarshal(raw, &res); err != nil {
		return SiteDoctorReport{}, fmt.Errorf("decode site doctor envelope: %w", err)
	}
	return res, nil
}
