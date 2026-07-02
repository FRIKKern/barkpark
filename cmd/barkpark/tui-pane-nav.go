package main

import "strings"

// scrollToField adjusts viewport to keep the focused field visible.
func (m *model) scrollToField() {
	// EXACT line offset, mirroring buildEditorContent's assembly: 4 header
	// lines, then each field's real rendered height + 1 separator. The old
	// ~3-lines-per-field approximation undershot badly on boxed fields
	// (label + 3 box rows + gap ≈ 5–6 lines), so the viewport stopped
	// following around field ~13 and the tail of a long form (a task's
	// claim/dependencies) was unreachable by keyboard.
	if !m.vpReady || m.editorSchema == nil {
		return
	}
	targetLine := 4
	fieldWidth := m.calcEditorWidth() - 4
	if fieldWidth < 20 {
		fieldWidth = 20
	}
	for i := 0; i < m.fieldCursor && i < len(m.editorSchema.Fields); i++ {
		// PHYSICAL lines, not slice elements: renderField returns a box as ONE
		// element with embedded newlines (label + bordered box ≈ 4–8 physical
		// rows in 2 elements), so a bare len() undercounted every boxed field
		// and the viewport stopped following partway down boxed-heavy forms.
		// The probe passes isEditing=false for every preceding field, which is
		// also EXACT while a textarea edit is live: the textarea View() is
		// height-pinned at startFieldEdit, so the editing render of a field
		// occupies the same span as its static render (pinned in
		// multiline_test.go).
		if m.fieldGroupHeader(i) != "" {
			targetLine += 2 // header + blank, mirroring buildEditorContent
		}
		targetLine += renderedLineCount(m.renderField(m.editorSchema.Fields[i], fieldWidth, false, false)) + 1
	}
	// The cursor's OWN group header (rendered before it) shifts its start too.
	if m.fieldCursor < len(m.editorSchema.Fields) && m.fieldGroupHeader(m.fieldCursor) != "" {
		targetLine += 2
	}
	if targetLine > m.viewport.YOffset+m.viewport.Height-6 {
		m.viewport.SetYOffset(targetLine - m.viewport.Height + 8)
	} else if targetLine < m.viewport.YOffset+2 {
		m.viewport.SetYOffset(maxInt(targetLine-2, 0))
	}
}

// renderedLineCount sums the PHYSICAL line count of renderField output — each
// slice element may itself be a multi-line lipgloss box render, so the slice
// length alone is not a height.
func renderedLineCount(chunks []string) int {
	n := 0
	for _, c := range chunks {
		n += strings.Count(c, "\n") + 1
	}
	return n
}

// syncPaneScroll recomputes and persists the pane's scroll offset for the
// current focused-pane box height, so cursor-follow windowing survives across
// renders. Called after every cursor move in a list pane.
func (m *model) syncPaneScroll(pane *Pane) {
	ih := m.listInteriorHeight(m.paneHeight())
	pane.Scroll = m.listScrollOffset(*pane, m.paneWidth(), ih)
}

// clampToItem clamps idx to [0, len-1] and, if it lands on a divider, walks in
// direction dir (+1/-1) to the nearest real item. If that walk runs off the end
// (a trailing/leading run of dividers), it reverses and walks inward instead, so
// the cursor never strands on a non-selectable divider. When every item is a
// divider there is nowhere to go: it returns the clamped idx rather than looping.
// Dividers are user-authorable via S.divider(), so leading/trailing ones happen.
func clampToItem(items []PaneItem, idx, dir int) int {
	n := len(items)
	if n == 0 {
		return 0
	}
	if idx < 0 {
		idx = 0
	}
	if idx > n-1 {
		idx = n - 1
	}
	if !items[idx].IsDivider {
		return idx
	}
	// Walk in the requested direction to the next real item.
	for i := idx + dir; i >= 0 && i < n; i += dir {
		if !items[i].IsDivider {
			return i
		}
	}
	// Ran off the end past a divider run — reverse and walk inward.
	for i := idx - dir; i >= 0 && i < n; i -= dir {
		if !items[i].IsDivider {
			return i
		}
	}
	// Every item is a divider: nothing selectable, keep the clamped index.
	return idx
}

// movePaneCursor moves the cursor by delta items (clamped, skipping dividers in
// the direction of travel) and re-persists the scroll offset. Used by pgup/pgdn.
func (m *model) movePaneCursor(pane *Pane, delta int) {
	if len(pane.Items) == 0 {
		return
	}
	dir := 1
	if delta < 0 {
		dir = -1
	}
	pane.Cursor = clampToItem(pane.Items, pane.Cursor+delta, dir)
	m.syncPaneScroll(pane)
}

// jumpPaneCursor sets the cursor to a specific index (clamped, skipping a
// trailing/leading divider) and re-persists the scroll offset. Used by g/G.
func (m *model) jumpPaneCursor(pane *Pane, target int) {
	if len(pane.Items) == 0 {
		return
	}
	// Walk inward from the extreme: from index 0 go forward, from the last go back.
	dir := 1
	if target >= len(pane.Items)-1 {
		dir = -1
	}
	pane.Cursor = clampToItem(pane.Items, target, dir)
	m.syncPaneScroll(pane)
}
