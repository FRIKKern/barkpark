package main

import (
	"fmt"
	"strings"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  BULK PUBLISH / UNPUBLISH                                                 ║
// ║                                                                          ║
// ║  Studio-E3 parity for the terminal. `space` on a doc-list row marks /    ║
// ║  unmarks it (✓ prefix); with marks present, `ctrl+p` publishes every     ║
// ║  marked doc and `U` unpublishes them — the same keys the editor uses     ║
// ║  for one doc, widened to the marked set when the focus is a list pane.   ║
// ║  `esc` clears the marks first (the second esc navigates back as usual).  ║
// ║                                                                          ║
// ║  Marks key on the BARE published id + remember the doc type (Studio's    ║
// ║  MapSet of published ids), so a mark survives the draft↔published id     ║
// ║  flip an action causes. Each id mutates individually; failures count     ║
// ║  and the first error is shown verbatim — partial success is normal      ║
// ║  (e.g. publish over a mix of drafts and already-published docs).         ║
// ╚══════════════════════════════════════════════════════════════════════════╝

// cursorDocItem returns the focused doc-list pane's highlighted doc row, or
// nil when the focus is not on a doc row (structure rows, editor, dividers).
func (m *model) cursorDocItem() *PaneItem {
	if m.focus.Target != FocusPane || m.focus.PaneIndex >= len(m.panes) {
		return nil
	}
	pane := &m.panes[m.focus.PaneIndex]
	if !pane.IsDocList || pane.Cursor >= len(pane.Items) {
		return nil
	}
	item := &pane.Items[pane.Cursor]
	if item.Doc == nil {
		return nil
	}
	return item
}

// markKey returns the marked-set key for a doc row: the bare published id.
func markKey(item *PaneItem) string {
	return strings.TrimPrefix(item.Doc.ID, "drafts.")
}

// toggleMark marks/unmarks the highlighted doc-list row (space in a pane).
func (m *model) toggleMark() {
	item := m.cursorDocItem()
	if item == nil {
		return
	}
	typeName := ""
	if item.SourceNode != nil {
		typeName = item.SourceNode.TypeName
	}
	if typeName == "" && item.Doc != nil {
		typeName = item.Doc.Type
	}
	if typeName == "" {
		return
	}

	if m.marked == nil {
		m.marked = make(map[string]string)
	}
	key := markKey(item)
	if _, ok := m.marked[key]; ok {
		delete(m.marked, key)
	} else {
		m.marked[key] = typeName
	}
}

// clearMarks empties the marked set (esc in a pane while marks exist).
func (m *model) clearMarks() {
	m.marked = nil
}

// bulkPublish / bulkUnpublish run the action over every marked doc. Each id
// mutates individually; the status line reports done/failed counts with the
// first error verbatim. Marks clear afterwards and the panes re-query.
func (m *model) bulkPublish()   { m.bulkAction("publish") }
func (m *model) bulkUnpublish() { m.bulkAction("unpublish") }

func (m *model) bulkAction(action string) {
	if len(m.marked) == 0 {
		return
	}

	done, failed := 0, 0
	firstErr := ""
	for id, typeName := range m.marked {
		var err error
		if action == "publish" {
			err = m.ds.Publish(typeName, id)
		} else {
			err = m.ds.Unpublish(typeName, id)
		}
		if err != nil {
			failed++
			if firstErr == "" {
				firstErr = err.Error()
			}
			continue
		}
		done++
	}

	m.marked = nil
	m.refreshDocViews()

	verb := action + "ed"
	if failed > 0 {
		m.setStatus(fmt.Sprintf("%s %d, %d failed: %s", verb, done, failed, firstErr), true)
		return
	}
	m.setStatus(fmt.Sprintf("%s %d", verb, done), false)
}
