package cloud

import "testing"

// TestParseLaunchHostReadsWhatTheWriterSends round-trips both captions through
// the console framing the provisioner uses ("create: progress — <caption>").
func TestParseLaunchHostReadsWhatTheWriterSends(t *testing.T) {
	why := "warm pool is off on the worker (WARM_POOL_SIZE=0)"
	for _, tc := range []struct {
		line string
		want LaunchHost
	}{
		{"create: progress — " + WarmHostCaption("warm-52d0bbcf"), LaunchHost{Warm: true, Name: "warm-52d0bbcf"}},
		{"create: progress — " + ColdHostCaption(why), LaunchHost{Why: why}},
		{ColdHostCaption("warm claim failed: a — b"), LaunchHost{Why: "warm claim failed: a — b"}},
		// A line written before the wording said "claimed".
		{"create: progress — Warm server warm-1 assigned", LaunchHost{Warm: true, Name: "warm-1"}},
	} {
		got, ok := ParseLaunchHost(tc.line)
		if !ok || got != tc.want {
			t.Errorf("ParseLaunchHost(%q) = %+v, %v; want %+v", tc.line, got, ok, tc.want)
		}
	}
	for _, line := range []string{"create: started", "provisioning acme.barkpark.cloud (nbg1 / cx23)…", "warm server warm-1 failed"} {
		if got, ok := ParseLaunchHost(line); ok {
			t.Errorf("ParseLaunchHost(%q) = %+v, want no match", line, got)
		}
	}
}

// TestLastLaunchHostTakesTheLaterLine: a failed assign writes a cold line after
// the warm one, and the cold line is the answer.
func TestLastLaunchHostTakesTheLaterLine(t *testing.T) {
	lines := []string{
		"create: progress — " + WarmHostCaption("warm-1"),
		"create: progress — " + ColdHostCaption("warm server warm-1 failed to assign: boom"),
		"create: started",
	}
	got, ok := LastLaunchHost(lines)
	if !ok || got.Warm || got.Why != "warm server warm-1 failed to assign: boom" {
		t.Fatalf("LastLaunchHost = %+v, %v; want the cold line", got, ok)
	}
	if _, ok := LastLaunchHost([]string{"create: started"}); ok {
		t.Fatal("a console without the line must not match")
	}
}
