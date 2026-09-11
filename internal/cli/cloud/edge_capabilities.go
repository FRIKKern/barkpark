package cloud

import (
	_ "embed"
	"encoding/json"
	"fmt"
	"sort"
)

//go:embed edge_capabilities.json
var edgeCapabilitiesFixture []byte

// UnknownEdgeKey is the metadata key an edge row uses to name the capabilities
// THIS REPO'S CODE CANNOT ANSWER. It is deliberately NOT a capability: a bool
// would assert something either way, and both assertions would be lies for a
// provider we simply do not drive (see EdgeRow.Unknown).
const UnknownEdgeKey = "unknown"

// EdgeRow is one entry of the edge_capabilities.json fixture: which EDGE
// features a provider adds in front of a Barkpark box (dns/tls/cdn/tunnel/
// storage/edge_fn/full_host), plus the list of keys this repo cannot honestly
// answer for that provider.
//
// Capabilities is a GENERIC map[string]bool, not a fixed struct — and that is
// the whole point of this type existing next to ProviderRow. The COMPUTE matrix
// decodes into ProviderRow{Tier string; Capabilities}, whose embedded
// Capabilities is a fixed struct of compute verbs (core/catalog/archive/…).
// Feeding an edge row through that shape SILENTLY DROPS every edge key: a plain
// encoding/json unmarshal discards a JSON field with no matching struct field,
// without an error. The fixed struct is right for compute (a capability claimed
// but unimplemented must red the parity test against a real interface), and
// wrong for edge, where the key set is the contract and is meant to grow.
// TestEdgeKeysSurviveDecodeAndComputeStructDropsThem proves both halves.
//
// Unknown rides ALONGSIDE the bools exactly as ProviderRow.Tier does: a non-bool
// metadata key that the Elixir conduit's generic `is_boolean(value)` filter
// already drops without a single line of conduit change. An UNKNOWN key must
// never reach a surface as a capability — false would generate a gap reason
// ("the tls capability isn't available on this provider yet") that is simply
// untrue of a provider we do not drive, and true would claim an integration
// this repo does not have.
type EdgeRow struct {
	Capabilities map[string]bool
	Unknown      []string
}

// UnmarshalJSON splits a flat fixture row into its capability bools and the
// `unknown` metadata list. Any OTHER non-bool value is a hard error rather than
// a silent drop — the silent drop is the exact failure this type exists to
// prevent, so it may not be reintroduced by a typo in the fixture.
func (r *EdgeRow) UnmarshalJSON(b []byte) error {
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		return err
	}

	r.Capabilities = make(map[string]bool, len(raw))
	r.Unknown = nil

	for key, value := range raw {
		if key == UnknownEdgeKey {
			if err := json.Unmarshal(value, &r.Unknown); err != nil {
				return fmt.Errorf("cloud: edge row %q must be a list of capability names: %w", UnknownEdgeKey, err)
			}
			continue
		}

		var b bool
		if err := json.Unmarshal(value, &b); err != nil {
			return fmt.Errorf("cloud: edge capability %q must be a bool (or named in %q): %w", key, UnknownEdgeKey, err)
		}
		r.Capabilities[key] = b
	}

	sort.Strings(r.Unknown)
	return nil
}

// Answers reports whether this row states anything at all about `capability` —
// false for a key named in Unknown, and for a key the row omits entirely. A
// reading surface must not render a gap (or a claim) for a capability that
// answers false here.
func (r EdgeRow) Answers(capability string) bool {
	_, ok := r.Capabilities[capability]
	return ok
}

// LoadEdgeCapabilities decodes the committed edge_capabilities.json fixture —
// the EDGE sibling of the compute capability matrix (LoadCapabilities). This
// file is the CANONICAL Go source of the edge contract; the Elixir control plane
// serves a byte-COPY under cloud/priv/static/__fixtures__/, held in lockstep by
// a drift gate that lives on BOTH sides (TestEdgeFixtureCopyIsByteIdentical here
// and edge_capabilities_contract_test.exs there), so mutating either copy reds
// both suites.
func LoadEdgeCapabilities() (map[string]EdgeRow, error) {
	var m map[string]EdgeRow
	if err := json.Unmarshal(edgeCapabilitiesFixture, &m); err != nil {
		return nil, fmt.Errorf("cloud: decode edge_capabilities.json: %w", err)
	}
	return m, nil
}
