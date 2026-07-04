package taskboard

import "os"

// spinner.go — the in_progress motion vocabulary (charter D38, spec §2). The
// Braille spinner cycles the 10 frames ~80ms/frame, driven by the EXISTING
// bubbletea heartbeat (anim.Alive gates the tick; UIState.Frame is the injected
// index, 0 at rest). Consumption only — no ticker is started here. An idle board
// has Frame==0, so it is byte-stable and goldens hold. Reduced-motion freezes on
// the steady ⠿ frame; the ASCII escape hatch swaps the whole glyph set for
// no-tofu single-column ASCII on a font that cannot render Braille/geometric
// glyphs. NO_COLOR is handled for free by lipgloss (it drops the hue; the glyph
// alone still carries state).

// brailleFrames are the 10 spinner frames (spec §1/§2), cycled by Frame%10.
var brailleFrames = [10]string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"}

// brailleStill is the single steady frame reduced-motion / NO_MOTION freezes on
// (spec §2) — motion off, but the glyph still reads as "in progress".
const brailleStill = "⠿"

// spinnerGlyph is the in_progress glyph for a given heartbeat frame. Under
// reduced motion it freezes on ⠿; under ASCII mode it uses a 1-column ASCII
// spinner so nothing turns to tofu. The frame index is normalized so a negative
// or large Frame is always in range.
func spinnerGlyph(frame int) string {
	if asciiMode() {
		return asciiSpinner(frame)
	}
	if reducedMotion() {
		return brailleStill
	}
	return brailleFrames[((frame%10)+10)%10]
}

// asciiSpinner is the 1-column ASCII fallback spinner (`-\|/`), frozen on `*`
// under reduced motion.
func asciiSpinner(frame int) string {
	if reducedMotion() {
		return "*"
	}
	frames := [4]string{"-", "\\", "|", "/"}
	return frames[((frame%4)+4)%4]
}

// boardGlyph is the board's frame-aware status glyph: the animated spinner for
// in_progress, the steady spec glyph (StatusGlyph) otherwise. Callers tint it
// via glyphStyleFor (color = state).
func boardGlyph(lifecycle string, frame int) string {
	if lifecycle == lifeInProgress {
		return spinnerGlyph(frame)
	}
	return StatusGlyph(lifecycle)
}

// asciiGlyph maps a lifecycle to its 1-column ASCII glyph for the escape hatch
// (spec §3: `( )` ready · `[~]` wip · `[!]` blocked · `[v]` done · `[x]`
// cancelled — collapsed to single columns so the fixed 2-col gutter never
// shifts and nothing becomes tofu).
func asciiGlyph(lifecycle string) string {
	switch lifecycle {
	case lifeInProgress:
		return "~"
	case lifeBlocked:
		return "!"
	case lifeDone, lifeClosed:
		return "v"
	case lifeCancelled:
		return "x"
	case lifeReady:
		return "o"
	case lifeOpen:
		return "."
	default:
		return "."
	}
}

// reducedMotion reports whether the spinner should freeze — honored via the
// NO_MOTION env var (the terminal analog of prefers-reduced-motion, spec §2).
func reducedMotion() bool { return os.Getenv("NO_MOTION") != "" }

// asciiMode reports whether the ASCII escape hatch is on (a font that cannot
// render the Braille/geometric glyphs) — gated by BP_TASKS_ASCII (spec §3).
func asciiMode() bool { return os.Getenv("BP_TASKS_ASCII") != "" }
