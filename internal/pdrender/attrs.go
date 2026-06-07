package pdrender

import (
	"fmt"
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
		return int(v)
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
		// JSON numbers decode to float64; print integers without a ".0".
		if x == float64(int64(x)) {
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
