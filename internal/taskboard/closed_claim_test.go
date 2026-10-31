package taskboard

import (
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

func TestAClosedClaimDecodesAsClosedAndTheBoardWillNotCloseIt(t *testing.T) {
	cases := map[string]string{
		"both stamps":     `"closed_by":"drop-clock","closed_at":"2026-10-31T15:03:29.563882Z"`,
		"closed_by alone": `"closed_by":"drop-clock"`,
		"closed_at alone": `"closed_at":"2026-10-31T15:03:29.563882Z"`,
	}
	for name, stamp := range cases {
		t.Run(name, func(t *testing.T) {
			tasks, err := decodeTaskList([]byte(`{"docs":[{"doc_id":"c1","lifecycle_status":"blocked","claim":{"worker":"drop-clock","epoch":3,"ts_iso":"2026-10-31T14:54:06.843197Z",` + stamp + `}}]}`))
			if err != nil {
				t.Fatal(err)
			}
			if !tasks[0].Claim.Closed || tasks[0].Claim.Worker != "drop-clock" {
				t.Fatalf("a stamped claim must decode Closed and keep its worker; got %+v", tasks[0].Claim)
			}

			m := testModel(activeOrphans(tasks[0]))
			m.ui.Cursor = 1
			fired := false
			m.doClose = func(_ *apiclient.Client, _, _ string, _ int, _ string) ActionResult {
				fired = true
				return ActionResult{OK: true}
			}
			m, _ = step(t, m, runes("x"))
			_, cmd := step(t, m, runes("x"))
			if cmd != nil {
				cmd()
			}
			if fired {
				t.Errorf("x x on a closed claim sent a close")
			}
		})
	}
}

func TestALiveClaimDecodesOpen(t *testing.T) {
	tasks, err := decodeTaskList([]byte(`{"docs":[{"doc_id":"c1","claim":{"worker":"w","epoch":1,"ts_iso":"2026-10-31T14:54:06.843197Z"}}]}`))
	if err != nil {
		t.Fatal(err)
	}
	if tasks[0].Claim.Closed || !hasLiveClaim(tasks[0]) {
		t.Errorf("an unstamped claim is live; got %+v", tasks[0].Claim)
	}
}
