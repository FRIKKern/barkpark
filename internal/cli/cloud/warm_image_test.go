package cloud

import (
	"context"
	"errors"
	"testing"
)

// swapWarmListers installs fixture listers and restores + cache-resets on cleanup.
func swapWarmListers(t *testing.T, images, servers func(context.Context) (string, error)) {
	t.Helper()
	prevImg, prevSrv := WarmImageLister, WarmServerImageLister
	ResetWarmImageCache()
	if images != nil {
		WarmImageLister = images
	}
	if servers != nil {
		WarmServerImageLister = servers
	}
	t.Cleanup(func() {
		WarmImageLister, WarmServerImageLister = prevImg, prevSrv
		ResetWarmImageCache()
	})
}

func TestResolveWarmImage_NewestAvailableWins(t *testing.T) {
	calls := 0
	swapWarmListers(t, func(context.Context) (string, error) {
		calls++
		return `[
			{"id": 300, "status": "creating",  "created": "2026-07-06T09:00:00Z"},
			{"id": 100, "status": "available", "created": "2026-07-04T03:30:00Z"},
			{"id": 200, "status": "available", "created": "2026-07-05T03:30:00Z"}
		]`, nil
	}, nil)

	if got := ResolveWarmImage(context.Background()); got != "200" {
		t.Errorf("ResolveWarmImage = %q, want 200 (newest AVAILABLE; a still-creating bake never wins)", got)
	}
	// Cached: a second resolve within the TTL must not re-shell.
	if got := ResolveWarmImage(context.Background()); got != "200" {
		t.Errorf("cached resolve = %q, want 200", got)
	}
	if calls != 1 {
		t.Errorf("lister calls = %d, want 1 (second resolve served from cache)", calls)
	}
	// An explicit reset re-lists (the bake pipeline just published).
	ResetWarmImageCache()
	if got := ResolveWarmImage(context.Background()); got != "200" || calls != 2 {
		t.Errorf("post-reset resolve = %q (calls %d), want 200 with a fresh list", got, calls)
	}
}

func TestResolveWarmImage_FailsOpenToEmpty(t *testing.T) {
	swapWarmListers(t, func(context.Context) (string, error) {
		return "", errors.New("hcloud not installed")
	}, nil)
	if got := ResolveWarmImage(context.Background()); got != "" {
		t.Errorf("lister error must resolve to \"\" (env fallback), got %q", got)
	}

	swapWarmListers(t, func(context.Context) (string, error) { return "not json", nil }, nil)
	if got := ResolveWarmImage(context.Background()); got != "" {
		t.Errorf("bad json must resolve to \"\", got %q", got)
	}

	swapWarmListers(t, func(context.Context) (string, error) { return `[]`, nil }, nil)
	if got := ResolveWarmImage(context.Background()); got != "" {
		t.Errorf("no labeled snapshots must resolve to \"\", got %q", got)
	}
}

func TestFreshSpec_DynamicImageWithEnvFallback(t *testing.T) {
	t.Setenv("BARKPARK_SERVER_IMAGE", "424242")

	// A labeled bake exists → it wins over the env pin.
	swapWarmListers(t, func(context.Context) (string, error) {
		return `[{"id": 999, "status": "available", "created": "2026-07-06T03:30:00Z"}]`, nil
	}, nil)
	if got := FreshSpec(context.Background(), ProviderHetzner).Image; got != "999" {
		t.Errorf("FreshSpec image = %q, want the newest bake 999", got)
	}

	// No labeled bake → the env-pinned fallback survives untouched.
	swapWarmListers(t, func(context.Context) (string, error) { return `[]`, nil }, nil)
	if got := FreshSpec(context.Background(), ProviderHetzner).Image; got != "424242" {
		t.Errorf("FreshSpec fallback image = %q, want the env pin 424242", got)
	}
}

func TestWarmServerImages_ParsesNamesAndSkipsImageless(t *testing.T) {
	swapWarmListers(t, nil, func(context.Context) (string, error) {
		return `[
			{"name": "warm-aaa", "image": {"id": 100}},
			{"name": "warm-bbb", "image": {"id": 999}},
			{"name": "warm-ccc", "image": null},
			{"name": "", "image": {"id": 5}}
		]`, nil
	})

	images, err := WarmServerImages(context.Background())
	if err != nil {
		t.Fatalf("WarmServerImages: %v", err)
	}
	if len(images) != 2 || images["warm-aaa"] != "100" || images["warm-bbb"] != "999" {
		t.Errorf("images = %v, want warm-aaa→100 warm-bbb→999 only", images)
	}

	swapWarmListers(t, nil, func(context.Context) (string, error) {
		return "", errors.New("hcloud flake")
	})
	if _, err := WarmServerImages(context.Background()); err == nil {
		t.Error("a listing error must surface (the caller decides to skip)")
	}
}
