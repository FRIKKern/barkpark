package main

import (
	"fmt"

	"github.com/charmbracelet/bubbles/textinput"
	"github.com/charmbracelet/bubbles/viewport"
	tea "github.com/charmbracelet/bubbletea"
)

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case DataStoreRefreshMsg:
		m.refreshDocViews()
		return m, nil
	case tea.KeyMsg:
		return m.handleKey(msg)
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		ew := m.calcEditorWidth()
		ph := m.paneHeight()
		if !m.vpReady {
			m.viewport = viewport.New(ew, ph)
			m.viewport.KeyMap = viewport.KeyMap{} // disable default bindings
			m.vpReady = true
		} else {
			m.viewport.Width = ew
			m.viewport.Height = ph
		}
		if m.showEditor && m.selectedDoc != nil {
			m.viewport.SetContent(m.buildEditorContent(ew))
			// A width change reflows the editor content, so the focused field's
			// row may have moved; re-follow it or it sits off-screen until the
			// next j/k. Only meaningful while the editor holds focus.
			if m.focus.Target == FocusEditor {
				m.scrollToField()
			}
		}
		// Re-clamp every pane's persisted scroll against the new interior height
		// so a shrink can't strand the window past the end. The window re-derives
		// from Cursor next render anyway; this keeps Pane.Scroll honest meanwhile.
		ih := m.listInteriorHeight(ph)
		pw := m.paneWidth()
		for i := range m.panes {
			m.panes[i].Scroll = m.listScrollOffset(m.panes[i], pw, ih)
		}
	}
	return m, nil
}

// refreshDocViews re-queries every pane and re-points an open editor at the
// freshly-fetched copy of the same document. rebuildPanes nils selectedDoc and
// the doc-list case does not restore it, so the restore here is what lets a
// Studio edit (or a TUI mutation's optimistic re-query) re-render live —
// shared by the DataStoreRefreshMsg handler and the task quick-actions.
func (m *model) refreshDocViews() {
	prevID, prevType, hadEditor := "", "", m.showEditor
	prevFocus := m.focus
	if m.selectedDoc != nil {
		prevID, prevType = m.selectedDoc.ID, m.selectedDoc.Type
	}
	m.rebuildPanes()
	// Re-resolve the previously-selected doc against the freshly-queried panes
	// so its (possibly edited) blocks re-parse. Only needed when rebuildPanes
	// did not itself restore a selection (the doc-list drill-in case).
	if hadEditor && m.selectedDoc == nil && prevID != "" {
		if doc := m.findDocInPanes(prevID, prevType); doc != nil {
			m.selectedDoc = doc
			m.editorSchema = findSchema(prevType)
			m.showEditor = true
			m.syncSelectedPaper()
			// Restore editor focus too: rebuildPanes nils the editor state
			// before its focus clamp runs, so the clamp demoted FocusEditor to
			// the pane. Without this, EVERY SSE refresh while a doc is open
			// silently kicked focus out of the editor — the next ctrl+p/ctrl+s
			// landed on the pane and did nothing (caught live: publish right
			// after n-create no-opped because the create's own SSE echo had
			// stolen focus).
			if prevFocus.Target == FocusEditor {
				m.focus = prevFocus
			}
		}
	}
	if m.showEditor && m.selectedDoc != nil {
		m.refreshViewport()
	}
}

func (m model) handleKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	key := msg.String()

	// Any keystroke dismisses the transient status line. saveDocument re-sets
	// it after this, so the save outcome still surfaces on the ctrl+s press.
	m.clearStatus()

	// ── Scope selector modal: all input goes to the selector ──
	if m.selector.active {
		return m.handleSelectorKey(msg)
	}

	// ── Reference picker modal: all input goes to the picker ──
	if m.refPicker.active {
		return m.handleRefPickerKey(msg)
	}

	// ── Search results modal: j/k/enter/esc on the transient hit list ──
	if m.searchOpen {
		return m.handleSearchResultsKey(msg)
	}

	// ── Diff modal: j/k scroll, esc/q/d dismiss (diff.go). Checked BEFORE
	//    history so a revision diff stacks over the list — closing it falls
	//    back to the still-open history modal. ──
	if m.diffOpen {
		return m.handleDiffKey(msg)
	}

	// ── History modal: j/k/enter/esc on the revision list (history.go) ──
	if m.historyOpen {
		return m.handleHistoryKey(msg)
	}

	// ── Help overlay: j/k scroll, ?/esc/q dismiss (help.go) ──
	if m.helpOpen {
		return m.handleHelpKey(msg)
	}

	// ── Search query prompt: all input goes to the text input ──
	if m.searching {
		switch key {
		case "esc":
			// Cancel the prompt, discard the typed query.
			m.searching = false
		case "enter":
			return m.commitSearch()
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	// ── New-document title prompt: all input goes to the text input ──
	if m.creating {
		switch key {
		case "esc":
			// Cancel the prompt, discard the typed title.
			m.creating = false
		case "enter":
			return m.commitCreateDoc()
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			return m, cmd
		}
		return m, nil
	}

	// ── Editing mode: all input goes to the active edit widget ──
	if m.editing {
		// Multi-line (textarea — FieldText / legacy-string FieldRichText):
		// enter must INSERT A NEWLINE, not commit, so the commit key moves to
		// ctrl+s. The first ctrl+s commits the field and leaves editing; the
		// NEXT ctrl+s (no longer editing) is the existing document save below.
		if m.editingMultiline {
			switch key {
			case "esc":
				// Cancel edit, discard input
				m.editing = false
				m.editingMultiline = false
			case "ctrl+s":
				// Commit edit to dirty values (a refused commit keeps editing)
				if m.commitFieldEdit() {
					m.editing = false
					m.editingMultiline = false
				}
			default:
				var cmd tea.Cmd
				m.textArea, cmd = m.textArea.Update(msg)
				// Live re-render + scroll-follow: the textarea's rendered box
				// keeps the height SetHeight pinned at startFieldEdit, but
				// scrollToField must still run per keystroke so the focused
				// box stays in view when editing near the bottom of the form
				// (j/k are the only other callers and they never fire here).
				m.refreshViewport()
				m.scrollToField()
				return m, cmd
			}
			m.refreshViewport()
			return m, nil
		}
		switch key {
		case "esc":
			// Cancel edit, discard input
			m.editing = false
		case "enter":
			// Commit edit to dirty values (a refused commit keeps editing)
			if m.commitFieldEdit() {
				m.editing = false
			}
		default:
			var cmd tea.Cmd
			m.textInput, cmd = m.textInput.Update(msg)
			// Re-render so the typed text appears LIVE in the field box. Without
			// this the keystroke is captured (Enter would commit it) but the
			// viewport is never rebuilt, so you can't see what you're typing.
			m.refreshViewport()
			return m, cmd
		}
		m.refreshViewport()
		return m, nil
	}

	// ── Armed delete confirm: the second D deletes the doc resolved at ARM
	//    time; esc disarms silently (swallowed — it must not also navigate
	//    back); any other key disarms and then handles normally below. ──
	if m.deleteArmed {
		armedID, armedType := m.deleteDocID, m.deleteDocType
		m.deleteArmed = false
		m.deleteDocID, m.deleteDocType = "", ""
		switch key {
		case "D":
			return m.performDelete(armedID, armedType)
		case "esc":
			return m, nil
		}
	}

	// ── Armed discard-draft confirm: same two-press contract as delete. ──
	if m.discardArmed {
		armedID, armedType := m.discardDocID, m.discardDocType
		m.discardArmed = false
		m.discardDocID, m.discardDocType = "", ""
		switch key {
		case "R":
			return m.performDiscard(armedID, armedType)
		case "esc":
			return m, nil
		}
	}

	// ── Read-only paper: the editor is a scroll surface, not a field form ──
	// A focused paper BYPASSES every field-editing handler (startFieldEdit,
	// toggleField, commitFieldEdit, ctrl+s save) — a paper is read-only in the
	// TUI (the documented v1 constraint; editing happens in Studio). Scroll the
	// viewport directly; the ~3-lines-per-field scrollToField heuristic does not
	// apply to free-form blocks. Pane/back navigation still works.
	if m.focus.Target == FocusEditor && m.isCurrentPaper() {
		switch key {
		case "q", "ctrl+c":
			return m, tea.Quit
		case "?":
			m.helpOpen = true
			m.helpScroll = 0
			return m, nil
		case "s":
			return m, m.openSelector()
		case "j", "down":
			if m.vpReady {
				m.viewport.ScrollDown(1)
			}
			return m, nil
		case "k", "up":
			if m.vpReady {
				m.viewport.ScrollUp(1)
			}
			return m, nil
		case "ctrl+d", "pgdown":
			if m.vpReady {
				m.viewport.HalfPageDown()
			}
			return m, nil
		case "ctrl+u", "pgup":
			if m.vpReady {
				m.viewport.HalfPageUp()
			}
			return m, nil
		case " ":
			if m.vpReady {
				m.viewport.PageDown()
			}
			return m, nil
		case "g", "home":
			if m.vpReady {
				m.viewport.GotoTop()
			}
			return m, nil
		case "G", "end":
			if m.vpReady {
				m.viewport.GotoBottom()
			}
			return m, nil
		case "h", "left", "shift+tab", "backspace", "esc":
			// Leave the paper, back to the last pane (mirrors the field editor).
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
			return m, nil
		}
		// Any other key is a no-op on a read-only paper (no edit, no toggle).
		return m, nil
	}

	// ── Save ──
	if key == "ctrl+s" && m.focus.Target == FocusEditor && m.dirty {
		m.saveDocument()
		m.refreshViewport()
		return m, nil
	}

	// ── Publish (publish-only by design: ctrl+p never unpublishes) ──
	if key == "ctrl+p" && m.focus.Target == FocusEditor {
		m.publishDocument()
		m.refreshViewport()
		return m, nil
	}

	// ── Unpublish (`U`, editor only) — ctrl+p's peer on a separate key so
	//    neither action can fat-finger into the other. Inert on drafts. ──
	if key == "U" && m.focus.Target == FocusEditor {
		m.unpublishDocument()
		m.refreshViewport()
		return m, nil
	}

	// ── Bulk publish/unpublish (Studio-E3 parity — bulk.go): the same two
	//    keys, widened to the marked set when the focus is a list pane. ──
	if key == "ctrl+p" && m.focus.Target == FocusPane && len(m.marked) > 0 {
		m.bulkPublish()
		return m, nil
	}
	if key == "U" && m.focus.Target == FocusPane && len(m.marked) > 0 {
		m.bulkUnpublish()
		return m, nil
	}

	// ── Diff (`d`, editor only) — draft↔published field diff (diff.go).
	//    The look-before-you-leap step for ctrl+p / R×2. ──
	if key == "d" && m.focus.Target == FocusEditor {
		m.openDiffView()
		return m, nil
	}

	// ── History (`H`, editor only) — revision list + diff-vs-current
	//    (history.go). Read-only; restore stays in Studio / the API. ──
	if key == "H" && m.focus.Target == FocusEditor {
		m.openHistoryView()
		return m, nil
	}

	switch key {

	case "q", "ctrl+c":
		return m, tea.Quit

	// ── Help overlay (`?` — help.go): the full key reference ──
	case "?":
		m.helpOpen = true
		m.helpScroll = 0
		return m, nil

	// ── Open scope selector (workspace/project/dataset) ──
	case "s":
		return m, m.openSelector()

	// ── Switch pane / drill ──
	case "tab":
		if m.focus.Target == FocusPane {
			if m.focus.PaneIndex < len(m.panes)-1 {
				m.focus.PaneIndex++
			} else if m.showEditor {
				m.focus.Target = FocusEditor
				m.fieldCursor = 0
			}
		}

	case "l", "right":
		// → / l ENTERS the highlighted item (Miller-column navigation): drill into
		// it exactly like Enter — open its children as the next column and move
		// focus there, or open a document in the editor. Re-drilling after the
		// cursor moved replaces any stale rightward columns (drillIn truncates the
		// path at the focused pane). tab still cycles focus between already-open
		// panes without drilling; ← / h leaves (focus to the parent column, pop at
		// the root, exit the editor).
		if m.focus.Target == FocusPane {
			return m.drillIn()
		}

	case "shift+tab":
		if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if m.focus.PaneIndex > 0 {
			m.focus.PaneIndex--
		}

	case "h", "left":
		if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if m.focus.PaneIndex > 0 {
			m.focus.PaneIndex--
		} else if len(m.path) > 0 {
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
		}

	// ── Navigate within pane / editor fields ──
	case "j", "down":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			// clampToItem walks past a divider forward, then back inward if that
			// runs off the end, so a trailing divider never strands the cursor.
			pane.Cursor = clampToItem(pane.Items, pane.Cursor+1, +1)
			m.syncPaneScroll(pane)
		} else if m.focus.Target == FocusEditor && m.editorSchema != nil {
			if m.fieldCursor < len(m.editorSchema.Fields)-1 {
				m.fieldCursor++
			}
			m.scrollToField()
			m.refreshViewport()
		}

	case "k", "up":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			// clampToItem walks past a divider backward, then forward inward if
			// that runs off the top, so a leading divider never strands the cursor.
			pane.Cursor = clampToItem(pane.Items, pane.Cursor-1, -1)
			m.syncPaneScroll(pane)
		} else if m.focus.Target == FocusEditor {
			if m.fieldCursor > 0 {
				m.fieldCursor--
			}
			m.scrollToField()
			m.refreshViewport()
		}

	// ── Page / jump within a list pane (parity with the editor's scroll keys;
	//    the FocusEditor paper-scroll branch above owns these when the editor is
	//    focused, so there is no collision). ──
	case "pgdown":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.movePaneCursor(pane, +m.listInteriorHeight(m.paneHeight()))
		}

	case "pgup":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.movePaneCursor(pane, -m.listInteriorHeight(m.paneHeight()))
		}

	case "home", "g":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.jumpPaneCursor(pane, 0)
		}

	case "end", "G":
		if m.focus.Target == FocusPane {
			pane := &m.panes[m.focus.PaneIndex]
			m.jumpPaneCursor(pane, len(pane.Items)-1)
		}

	// ── New document (doc-list panes only — a pane that lists documents of a
	//    type, never a structure pane). Opens the one-line title prompt. ──
	case "n":
		if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) &&
			m.panes[m.focus.PaneIndex].IsDocList {
			m.startCreateDoc()
			return m, textinput.Blink
		}

	// ── Search (`/` on a focused pane only — never while editing text: the
	//    editing/creating/search-prompt branches above own those keystrokes,
	//    and the editor surfaces don't bind it). Opens the help-bar query
	//    input; enter runs the scoped search (see search.go). ──
	case "/":
		if m.focus.Target == FocusPane {
			m.startSearch()
			return m, textinput.Blink
		}

	// ── Delete (two-press confirm): the first D arms the status-bar prompt
	//    for the highlighted doc-list row or the open editor doc; the armed
	//    branch above handles the second press. ctrl+d was deliberately NOT
	//    used — it is the paper viewer's half-page-down. ──
	case "D":
		if doc, typeName := m.deleteTarget(); doc != nil {
			m.deleteArmed = true
			m.deleteDocID = doc.ID
			m.deleteDocType = typeName
			m.setStatus(fmt.Sprintf("delete %q? press D again to confirm · esc cancel", doc.Title), true)
		}
		return m, nil

	// ── Duplicate (`y` — yank a copy): clones the highlighted doc-list row or
	//    the open editor doc into a fresh draft titled "<title> (copy)",
	//    matching Studio's Duplicate header action, then drills into the new
	//    draft. Same target resolution as delete; inert on other surfaces.
	//    The paper viewer never reaches here (its branch above owns its keys),
	//    and Duplicate refuses papers anyway. ──
	case "y":
		if doc, typeName := m.deleteTarget(); doc != nil {
			return m.performDuplicate(doc, typeName)
		}

	// ── Discard draft (`R`×2 — revert to published): drops the highlighted
	//    or open doc's DRAFT, keeping the published version. Twin-guarded at
	//    arm time (the server isn't): a draft with no published twin refuses
	//    with a pointer to D, and a published doc has nothing to discard. ──
	case "R":
		if doc, typeName := m.deleteTarget(); doc != nil {
			m.armDiscard(doc, typeName)
		}
		return m, nil

	// ── Task quick actions (task doc-lists + an editor holding a task only;
	//    inert on every other surface) ──
	case "c":
		if doc := m.taskTarget(); doc != nil {
			m.claimTask(doc)
			return m, nil
		}

	case "x":
		if doc := m.taskTarget(); doc != nil {
			m.closeTask(doc)
			return m, nil
		}

	// ── Drill in / start editing ──
	case "enter":
		if m.focus.Target == FocusEditor && m.editorSchema != nil {
			cmd := m.startFieldEdit()
			m.refreshViewport()
			m.scrollToField()
			return m, cmd
		}
		return m.drillIn()

	// ── Toggle for boolean/select; mark for bulk on doc-list rows ──
	case " ":
		if m.focus.Target == FocusEditor && m.editorSchema != nil {
			m.toggleField()
			m.refreshViewport()
		} else if m.focus.Target == FocusPane {
			m.toggleMark()
		}

	// ── Go back (esc clears bulk marks first — second esc navigates) ──
	case "backspace", "esc":
		if m.focus.Target == FocusPane && len(m.marked) > 0 {
			m.clearMarks()
		} else if m.focus.Target == FocusEditor {
			m.focus = focusState{Target: FocusPane, PaneIndex: len(m.panes) - 1}
		} else if len(m.path) > 0 {
			m.path = m.path[:len(m.path)-1]
			m.rebuildPanes()
		}
	}

	return m, nil
}

// drillIn selects the highlighted item in the focused pane, same as Enter.
func (m model) drillIn() (tea.Model, tea.Cmd) {
	if m.focus.Target != FocusPane || m.focus.PaneIndex >= len(m.panes) {
		return m, nil
	}
	pane := &m.panes[m.focus.PaneIndex]
	if pane.Cursor >= len(pane.Items) {
		return m, nil
	}
	item := pane.Items[pane.Cursor]
	if item.IsDivider {
		return m, nil
	}
	if pane.IsDocList {
		m.selectedDoc = item.Doc
		m.editorSchema = findSchema(pane.Node.TypeName)
		m.showEditor = true
		m.focus.Target = FocusEditor
		m.fieldCursor = 0
		m.syncSelectedPaper()
		m.cacheRefTitlesFor(m.editorSchema)
		m.resetViewport()
	} else {
		m.path = m.path[:m.focus.PaneIndex]
		m.path = append(m.path, item.ID)
		m.rebuildPanes()
		if m.showEditor {
			m.focus.Target = FocusEditor
			m.fieldCursor = 0
			m.resetViewport()
		} else if m.focus.PaneIndex < len(m.panes)-1 {
			m.focus.PaneIndex++
		}
	}
	return m, nil
}
