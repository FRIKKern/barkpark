package main

import (
	"encoding/json"
	"os"
	"reflect"
	"testing"
)

// serverFixture is the capabilities literal the server's tests send through
// enrollment and heartbeat: api/test/barkpark/chat_hosts/go_host_capabilities_test.exs.
// The server once refused a key this binary sent (chat_runtime), and every real
// enrollment failed as "credential revoked" (task-c02eefeb0ed7381c). This test
// fails when capabilities() emits a key, a JSON type or a fixed value the
// fixture does not have. Change the fixture, the server check in
// api/lib/barkpark/chat_hosts/registered_host.ex and this binary together.
const serverFixture = "../../api/test/support/fixtures/chat_host_go_capabilities.json"

func TestCapabilitiesShapeMatchesServerFixture(t *testing.T) {
	raw, err := os.ReadFile(serverFixture)
	if err != nil {
		t.Fatalf("read server fixture: %v", err)
	}
	var fixture map[string]any
	if err := json.Unmarshal(raw, &fixture); err != nil {
		t.Fatalf("parse server fixture: %v", err)
	}

	encoded, err := json.Marshal(capabilities())
	if err != nil {
		t.Fatalf("marshal capabilities: %v", err)
	}
	var emitted map[string]any
	if err := json.Unmarshal(encoded, &emitted); err != nil {
		t.Fatalf("parse capabilities: %v", err)
	}

	assertShapeWithin(t, "capabilities", emitted, fixture)

	// Values the server checks against a fixed set, not only by type.
	for _, key := range []string{"protocol_version", "chat_runtime"} {
		if !reflect.DeepEqual(emitted[key], fixture[key]) {
			t.Errorf("capabilities.%s = %#v, server fixture has %#v", key, emitted[key], fixture[key])
		}
	}
	emittedProviders, _ := emitted["providers"].(map[string]any)
	fixtureProviders, _ := fixture["providers"].(map[string]any)
	for name, provider := range emittedProviders {
		got, _ := provider.(map[string]any)
		want, _ := fixtureProviders[name].(map[string]any)
		if !reflect.DeepEqual(got["operations"], want["operations"]) {
			t.Errorf("%s operations = %#v, server fixture has %#v", name, got["operations"], want["operations"])
		}
	}
}

// assertShapeWithin fails for every path in emitted that the fixture lacks or
// holds with another JSON type. Keys the binary emits only sometimes (version,
// when the provider CLI is installed) must be in the fixture, so the server
// test covers them.
func assertShapeWithin(t *testing.T, path string, emitted, fixture any) {
	t.Helper()
	switch got := emitted.(type) {
	case map[string]any:
		want, ok := fixture.(map[string]any)
		if !ok {
			t.Errorf("%s: emitted an object, server fixture has %T", path, fixture)
			return
		}
		for key, value := range got {
			expected, present := want[key]
			if !present {
				t.Errorf("%s.%s: emitted, but absent from the server fixture", path, key)
				continue
			}
			assertShapeWithin(t, path+"."+key, value, expected)
		}
	case []any:
		want, ok := fixture.([]any)
		if !ok || len(want) == 0 {
			t.Errorf("%s: emitted a list, server fixture has %#v", path, fixture)
			return
		}
		for _, value := range got {
			assertShapeWithin(t, path+"[]", value, want[0])
		}
	default:
		if reflect.TypeOf(emitted) != reflect.TypeOf(fixture) {
			t.Errorf("%s: emitted %T, server fixture has %T", path, emitted, fixture)
		}
	}
}
