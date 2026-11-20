package cloud

import "strings"

// launch_host_line.go owns the console line a Hetzner launch writes to say
// whether it took a warm server or creates a new one. The provisioner writes it
// (internal/provisioner/launch_host.go) and `bp cloud status` reads it back off
// the job's `provision_console`. Both sides call these functions, so the wording
// the reader looks for is the wording the writer sends.
//
//	Warm server warm-52d0bbcf claimed
//	No warm server: <why> — creating a new server
const (
	warmHostPrefix = "Warm server "
	warmHostSuffix = " claimed"
	coldHostPrefix = "No warm server: "
	coldHostSuffix = " — creating a new server"
)

// consoleStepSep is the separator the provisioner's console puts between a
// step's "create: progress" tag and its detail. The control plane can also put
// a cause in front of a line with the same separator.
const consoleStepSep = "— "

// WarmHostCaption is the line for a launch that claimed the warm server name.
// The provisioner sends it right after the claim, before the assign runs; a
// failed assign is followed by its own ColdHostCaption line.
func WarmHostCaption(name string) string { return warmHostPrefix + name + warmHostSuffix }

// ColdHostCaption is the line for a launch that creates a new server; why says
// why no warm server was used.
func ColdHostCaption(why string) string { return coldHostPrefix + why + coldHostSuffix }

// LaunchHost is what a launch's console said about its server: a claimed warm
// server (Warm, Name) or a new one (Why).
type LaunchHost struct {
	Warm bool
	Name string
	Why  string
}

// ParseLaunchHost reads one console line. It finds the caption at the start of
// the line or after a "— " separator, which is where it sits in the console's
// "create: progress — <caption>" framing. ok is false for any other line.
func ParseLaunchHost(line string) (h LaunchHost, ok bool) {
	if rest, found := afterCaptionPrefix(line, coldHostPrefix); found {
		return LaunchHost{Why: strings.TrimSuffix(rest, coldHostSuffix)}, true
	}
	if rest, found := afterCaptionPrefix(line, warmHostPrefix); found {
		// Read the name only, so a line written before the wording said
		// "claimed" ("Warm server <name> assigned") still parses.
		if name, _, _ := strings.Cut(rest, " "); name != "" {
			return LaunchHost{Warm: true, Name: name}, true
		}
	}
	return LaunchHost{}, false
}

// LastLaunchHost returns the last warm-or-cold line in a console. The last one
// is the answer: a warm server that fails to assign is followed by a cold line.
func LastLaunchHost(lines []string) (h LaunchHost, ok bool) {
	for i := len(lines) - 1; i >= 0; i-- {
		if h, ok := ParseLaunchHost(lines[i]); ok {
			return h, true
		}
	}
	return LaunchHost{}, false
}

func afterCaptionPrefix(line, prefix string) (string, bool) {
	if strings.HasPrefix(line, prefix) {
		return line[len(prefix):], true
	}
	if i := strings.Index(line, consoleStepSep+prefix); i >= 0 {
		return line[i+len(consoleStepSep)+len(prefix):], true
	}
	return "", false
}
