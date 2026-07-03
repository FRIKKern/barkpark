package taskboard

import (
	"fmt"
	"time"

	"github.com/charmbracelet/lipgloss"
)

// motion.go — wave-4 slice 20. Every function here is a pure projection of the
// injected clock and the heartbeat frame index (decision 16): no time.Now, no
// state. Motion is a MEASUREMENT — these helpers move only when real work does,
// and at rest they collapse to the still render (LiveElapsed only runs on NOW
// cards, the working verb only heads the ticker in flight, the flash style is a
// zero-value no-op at level 0).

// tenMinutes is the boundary below which a live claim shows SECONDS granularity
// and above which it degrades to AgeBadge's coarse vocabulary — a per-second
// tick past ten minutes is noise, not information.
const tenMinutes = 10 * time.Minute

// LiveElapsed is the ticking "time since a claim landed" token the NOW band
// wears — the one place real work runs, so the one place the heartbeat's second
// hand is honest (decision 19). Under ten minutes it counts SECONDS ("47s",
// "3m42s") so a watched claim visibly advances every tick; at ten minutes and
// beyond it hands off to AgeBadge's minute/hour/day vocabulary ("14m", "3h",
// "2d"). Clock skew is clamped exactly like AgeBadge — a claim stamped in the
// future never renders a negative stopwatch. Empty for a zero time, so a card
// with no claim costs no token.
func LiveElapsed(claimedAt, now time.Time) string {
	if claimedAt.IsZero() {
		return ""
	}
	d := now.Sub(claimedAt)
	if d < 0 { // server/client skew — never a negative stopwatch
		d = 0
	}
	if d >= tenMinutes {
		// Past ten minutes seconds are noise; AgeBadge owns the coarse vocabulary
		// (and its own skew clamp), so the token reads identically to every other
		// age on the board.
		return AgeBadge(claimedAt, now)
	}
	secs := int(d.Seconds())
	if secs < 60 {
		return fmt.Sprintf("%ds", secs)
	}
	// Zero-pad the seconds so a ticking clock keeps a stable width as it advances
	// (3m05s → 3m06s, never a 3m9s→3m10s column jump).
	return fmt.Sprintf("%dm%02ds", secs/60, secs%60)
}

// workingVerbs is WorkingVerb's small, curated, lowercase gerund list. Restrained
// by design (decision 19): personality is confined to the ticker's one waiting
// line, never an exclamation, never a data line. reticulating is the one wink.
var workingVerbs = []string{
	"working",
	"herding",
	"fetching",
	"closing",
	"shipping",
	"gathering",
	"tending",
	"reticulating",
}

// WorkingVerb is the ticker head's gerund, cycled from the heartbeat frame so it
// changes about every three seconds at the 1s tick cadence — each verb holds
// frame/3 (decision 19). It is a pure function of the frame index, so a motion
// golden at a fixed Frame is byte-stable (WorkingVerb(4) is always "herding").
// A negative frame clamps to the first verb.
func WorkingVerb(frame int) string {
	if frame < 0 {
		frame = 0
	}
	return workingVerbs[(frame/3)%len(workingVerbs)]
}

// flashStyle is the one-shot flash emphasis for a row whose task just changed
// (decision 17). It tints the FOREGROUND only — never a background block —
// reusing the info role that already means "moving" (theme.go owns every color,
// decision 11), so the flash is honest state, not decoration:
//
//   - level 2 (bright, <1.5s): the full info hue with bold weight — a title
//     that just landed and wants the eye for a beat;
//   - level 1 (fading remnant, <4s): the same info hue rendered faint — the
//     afterglow, one notch below the bold moment;
//   - level 0 (gone): the zero-value style — no emphasis at all, so a settled
//     row is byte-identical to the still render.
//
// The level-1 remnant is info-faint rather than the zinc dim so the fade stays
// in the SAME hue as the bright moment (a single decaying signal), and it adds
// no new palette entry.
func flashStyle(level int) lipgloss.Style {
	switch level {
	case 2:
		return infoStyle.Bold(true)
	case 1:
		return infoStyle.Faint(true)
	default:
		return lipgloss.NewStyle()
	}
}
