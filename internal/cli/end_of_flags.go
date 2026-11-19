package cli

// "--" ends the flags: every argument after it is positional however it
// looks, so a task title may start with "--" ("--perspective"), and the
// may-have-landed hint pastes it as `-- '<title>'` (task-379127ebdf341017).
//
// Only where a flag could start. A flag that takes a value takes the next
// argument even when it is "--", as parseGlobals does: `--description --` is
// the description "--" (task-27104d204de9620e). So each flag loop stops at a
// "--" it meets in a flag's place, and its value step consumes one that
// follows a value flag before the loop can see it.

// afterEndOfFlags is what follows the "--" at tail[i] that stopped a flag
// loop. Nil when the loop ran off the end of tail without one.
func afterEndOfFlags(tail []string, i int) []string {
	if i < len(tail) {
		return tail[i+1:]
	}
	return nil
}

// endOfFlags is the index of the "--" that ends the flags in tail, or
// len(tail), for a scan that knows only which arguments take the next one as
// their value.
func endOfFlags(tail []string, takesValue func(arg string) bool) int {
	for i := 0; i < len(tail); i++ {
		if tail[i] == "--" {
			return i
		}
		if takesValue(tail[i]) {
			i++
		}
	}
	return len(tail)
}
