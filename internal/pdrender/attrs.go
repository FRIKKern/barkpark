package pdrender

import (
	"fmt"
	"math"
	"strconv"
)

// Helpers for reading loosely-typed fields out of a decoded JSON block. The
// wire shape comes from Jason/encoding-json, so numbers may arrive as float64,
// json.Number, or int; the renderers must tolerate all of them — exactly the
// coercion tolerance compose_block/2 has on the Elixir side.

// attrStr reads a string field, coercing numbers/bools to their string form
// (mirrors `to_string/1`). Missing → "".
func attrStr(m map[string]any, key string) string {
	if m == nil {
		return ""
	}
	return toStr(m[key])
}

// attrStrDefault reads a string field, returning def when absent or empty.
func attrStrDefault(m map[string]any, key, def string) string {
	s := attrStr(m, key)
	if s == "" {
		return def
	}
	return s
}

// attrStrFirst reads the first NON-EMPTY string field among keys, coercing as
// attrStr does. This is the defensive dual-read for fields the wire emits under
// more than one name (e.g. code source = "code"||"value", code language =
// "language"||"lang") — the same "prefer the live key, fall back to the legacy
// key" discipline the client already uses (PaperBlocks prefers `blocks`, falls
// back to `content.blocks`). Returns "" when every key is absent/empty.
func attrStrFirst(m map[string]any, keys ...string) string {
	for _, k := range keys {
		if s := attrStr(m, k); s != "" {
			return s
		}
	}
	return ""
}

// attrBool reads a strict boolean field; anything else → false (mirrors the
// `== true` checks in render.ex, e.g. ordered lists and field-boolean).
func attrBool(m map[string]any, key string) bool {
	if m == nil {
		return false
	}
	b, _ := m[key].(bool)
	return b
}

// attrInt reads an integer-ish field with a default, tolerating float64 /
// json.Number / string encodings.
func attrInt(m map[string]any, key string, def int) int {
	if m == nil {
		return def
	}
	switch v := m[key].(type) {
	case int:
		return v
	case int64:
		return int(v)
	case float64:
		// JSON numbers decode to float64; only coerce whole values that fit
		// int64 — an overflowing float->int conversion is implementation-defined
		// in Go (mirrors the guard in toStr below).
		if v == math.Trunc(v) && v >= math.MinInt64 && v < math.MaxInt64 {
			return int(v)
		}
	case string:
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	case fmt.Stringer:
		if n, err := strconv.Atoi(v.String()); err == nil {
			return n
		}
	}
	return def
}

// attrSlice reads a field expected to be a JSON array → []any. Missing/wrong
// type → nil.
func attrSlice(m map[string]any, key string) []any {
	if m == nil {
		return nil
	}
	s, _ := m[key].([]any)
	return s
}

// toStr coerces an arbitrary decoded JSON scalar to a display string, matching
// Elixir's `to_string/1` tolerance (strings pass through, numbers stringify,
// bools → "true"/"false", nil → "").
func toStr(v any) string {
	switch x := v.(type) {
	case nil:
		return ""
	case string:
		return x
	case bool:
		if x {
			return "true"
		}
		return "false"
	case float64:
		// JSON numbers decode to float64; print whole numbers without a ".0",
		// but only when the value fits int64 — a float->int conversion that
		// overflows is implementation-defined in Go.
		if x == math.Trunc(x) && x >= math.MinInt64 && x < math.MaxInt64 {
			return strconv.FormatInt(int64(x), 10)
		}
		return strconv.FormatFloat(x, 'g', -1, 64)
	case int:
		return strconv.Itoa(x)
	case int64:
		return strconv.FormatInt(x, 10)
	case fmt.Stringer:
		return x.String()
	default:
		return fmt.Sprintf("%v", x)
	}
}

// clampWidth never lets a width go below 1, so lipgloss/ansi.Wrap never gets a
// degenerate limit.
func clampWidth(w int) int {
	if w < 1 {
		return 1
	}
	return w
}
