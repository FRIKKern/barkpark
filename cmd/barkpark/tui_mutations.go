package main

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"

	"github.com/FRIKKern/barkpark/internal/apiclient"
	"github.com/FRIKKern/barkpark/internal/taskboard"
	"github.com/charmbracelet/bubbles/textinput"
	tea "github.com/charmbracelet/bubbletea"
)

// saveDocument sends dirty values to the API as a patch mutation.
func (m *model) saveDocument() {
	if m.selectedDoc == nil || !m.dirty || len(m.dirtyValues) == 0 {
		return
	}

	setFields := make(map[string]interface{})
	for k, v := range m.dirtyValues {
		// TYPED SAVE for arrays: the server's patch path merges the "set" map
		// verbatim — no coercion — so a Go string here would store the literal
		// string "[\"a\",\"b\"]" over a JSON array and silently change the
		// stored JSONB type (confirmed by live probe). Send the raw JSON array
		// for a FieldArray value that parses as one; everything else keeps the
		// string behaviour byte-identically.
		if f := m.editorField(k); f != nil {
			switch f.Type {
			case FieldArray:
				var arr []interface{}
				if json.Unmarshal([]byte(v), &arr) == nil {
					setFields[k] = json.RawMessage(v)
					continue
				}
			case FieldNumber:
				// Schema validators (task.priority: integer 0..4) hard-reject
				// strings; commitFieldEdit already validated the text.
				if n, err := strconv.ParseInt(strings.TrimSpace(v), 10, 64); err == nil {
					setFields[k] = n
					continue
				}
				if fl, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
					setFields[k] = fl
					continue
				}
			case FieldBoolean:
				// toggleField writes "true"/"false" strings — store real bools
				// (the audit's silent-type-flip finding).
				if v == "true" || v == "false" {
					setFields[k] = v == "true"
					continue
				}
			}
		}
		setFields[k] = v
	}

	mutation := map[string]interface{}{
		"patch": map[string]interface{}{
			"id":   m.selectedDoc.ID,
			"type": m.editorSchema.Name,
			"set":  setFields,
		},
	}

	if err := m.ds.Mutate([]map[string]interface{}{mutation}); err != nil {
		// Surface the failure — a tenancy 403, a 422 validation reject, or a
		// network drop would otherwise vanish and leave the doc dirty with no
		// feedback. The error string carries the status code + server body.
		m.setStatus(fmt.Sprintf("save failed: %v", err), true)
		return
	}
	m.dirtyValues = nil
	m.dirty = false
	m.setStatus("saved", false)
}

// publishDocument promotes the selected DRAFT to published via the publish
// mutation. Publish-only by design: a non-draft document is a silent no-op
// (the footer renders "published ✓" with no action). Unsaved changes block the
// publish — the server copies ITS draft to the published id, so unsaved local
// edits would silently miss the published document.
func (m *model) publishDocument() {
	if m.selectedDoc == nil || m.editorSchema == nil || m.selectedDoc.Status != "draft" {
		return
	}
	if m.dirty {
		m.setStatus("save first (ctrl+s)", true)
		return
	}
	// The mutate contract takes the BARE published id ({"publish":{"id":"x",
	// "type":"post"}}) — strip the drafts. prefix; the server derives the
	// drafts. twin itself.
	id := strings.TrimPrefix(m.selectedDoc.ID, "drafts.")
	if err := m.ds.Publish(m.editorSchema.Name, id); err != nil {
		m.setStatus(fmt.Sprintf("publish failed: %v", err), true)
		return
	}
	// Optimistic flip, like saveDocument's in-memory apply — the SSE refresh
	// will re-query and confirm. The published doc now lives at the bare id.
	m.selectedDoc.Status = "published"
	m.selectedDoc.ID = id
	m.setStatus("published", false)
}

// unpublishDocument demotes the open PUBLISHED doc back to a draft (`U` in
// the editor) — the missing peer of ctrl+p, which stays publish-only by
// design (separate keys so neither action can fat-finger into the other).
// The mutate contract takes the bare published id ({"unpublish":{"id":"x",
// "type":…}}); the server moves the row to its drafts. twin, mirrored here
// by the optimistic flip.
func (m *model) unpublishDocument() {
	if m.selectedDoc == nil || m.editorSchema == nil || m.selectedDoc.Status != "published" {
		return
	}
	id := strings.TrimPrefix(m.selectedDoc.ID, "drafts.")
	if err := m.ds.Unpublish(m.editorSchema.Name, id); err != nil {
		m.setStatus(fmt.Sprintf("unpublish failed: %v", err), true)
		return
	}
	m.selectedDoc.Status = "draft"
	m.selectedDoc.ID = "drafts." + id
	m.setStatus("unpublished — now a draft", false)
}

// startCreateDoc opens the one-line title prompt for a new document of the
// focused doc-list pane's type. Reuses the field-edit textinput mechanics;
// the input renders in the help bar (see renderHelpBar's creating branch).
func (m *model) startCreateDoc() {
	pane := m.panes[m.focus.PaneIndex]
	m.creating = true
	m.creatingType = pane.Node.TypeName
	m.textInput = textinput.New()
	m.textInput.Focus()
	m.textInput.CharLimit = 200
	m.textInput.Width = maxInt(m.width-30, 20)
	m.textInput.Prompt = ""
}

// creatingTypeTitle returns the human title of the schema being created
// ("Post"), falling back to the machine type name when the schema is unknown.
func (m model) creatingTypeTitle() string {
	if s := findSchema(m.creatingType); s != nil && s.Title != "" {
		return s.Title
	}
	return m.creatingType
}

// commitCreateDoc sends the create mutation for the typed title — with NO _id,
// so the server assigns drafts.<type>-<n> — then re-queries the panes and
// drills into the new document's editor. Esc never reaches here (the creating
// branch handles it); an empty title cancels with an error status.
func (m model) commitCreateDoc() (tea.Model, tea.Cmd) {
	m.creating = false
	title := strings.TrimSpace(m.textInput.Value())
	if title == "" {
		m.setStatus("title required", true)
		return m, nil
	}
	id, err := m.ds.Create(m.creatingType, title)
	if err != nil {
		m.setStatus(fmt.Sprintf("create failed: %v", err), true)
		return m, nil
	}
	// Optimistic refresh: re-query the panes NOW (the SSE refresh will also
	// fire) so the new doc appears in its list, then select + drill in.
	m.rebuildPanes()
	m.selectAndOpenDoc(id, m.creatingType)
	m.setStatus("created "+title, false)
	return m, nil
}

// selectAndOpenDoc parks the doc-list cursor on the (just re-queried) doc and
// drills into its editor — the shared landing for create and duplicate. A doc
// not found in any pane (e.g. filtered out) is a no-op; the status line still
// reports the outcome.
func (m *model) selectAndOpenDoc(id, typeName string) {
	doc := m.findDocInPanes(id, typeName)
	if doc == nil {
		return
	}
	// Park the doc-list cursor on the new doc so esc-back lands on it.
	for pi := range m.panes {
		pane := &m.panes[pi]
		if !pane.IsDocList {
			continue
		}
		for ii := range pane.Items {
			if pane.Items[ii].Doc != nil && pane.Items[ii].Doc.ID == id {
				pane.Cursor = ii
				m.focus = focusState{Target: FocusPane, PaneIndex: pi}
				m.syncPaneScroll(pane)
			}
		}
	}
	m.selectedDoc = doc
	m.editorSchema = findSchema(typeName)
	m.showEditor = true
	m.focus.Target = FocusEditor
	m.fieldCursor = 0
	m.syncSelectedPaper()
	m.resetViewport()
}

// performDuplicate clones the doc via Client.Duplicate — the same shape
// Studio's duplicate-doc lands server-side (fresh draft, " (copy)" title,
// content copied verbatim) — then re-queries and drills into the new draft,
// mirroring Studio's push_patch onto the duplicate. Papers refuse inside
// Duplicate with a pointer to Studio.
func (m model) performDuplicate(src *Doc, typeName string) (tea.Model, tea.Cmd) {
	id, err := m.ds.Duplicate(typeName, src.ID)
	if err != nil {
		m.setStatus(fmt.Sprintf("duplicate failed: %v", err), true)
		return m, nil
	}
	m.rebuildPanes()
	m.selectAndOpenDoc(id, typeName)
	m.setStatus("duplicated as "+id, false)
	return m, nil
}

// deleteTarget resolves the document a D-press would delete: the highlighted
// row of the focused doc-list pane, or the open editor doc when the editor has
// focus. Returns (nil, "") on every other surface (structure panes, dividers,
// no selection) so D stays inert there.
func (m model) deleteTarget() (*Doc, string) {
	if m.focus.Target == FocusEditor && m.selectedDoc != nil && m.editorSchema != nil {
		return m.selectedDoc, m.editorSchema.Name
	}
	if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) {
		pane := m.panes[m.focus.PaneIndex]
		if pane.IsDocList && pane.Node != nil && pane.Cursor < len(pane.Items) {
			if doc := pane.Items[pane.Cursor].Doc; doc != nil {
				return doc, pane.Node.TypeName
			}
		}
	}
	return nil, ""
}

// performDelete deletes the armed document via the delete mutation
// ({"delete":{"id":…,"type":…}}, matching Content.apply_one's delete arm).
// The id goes over the wire EXACTLY as listed — drafts. prefix included — per
// the API contract for drafts vs published rows. If the deleted doc is open
// in the editor we pop out first; either way the panes re-query so the row
// disappears now (the SSE refresh will confirm).
func (m model) performDelete(docID, typeName string) (tea.Model, tea.Cmd) {
	if err := m.ds.Delete(typeName, docID); err != nil {
		m.setStatus(fmt.Sprintf("delete failed: %v", err), true)
		return m, nil
	}
	if m.showEditor && m.selectedDoc != nil && m.selectedDoc.ID == docID {
		// Pop out of the deleted doc's editor — there is nothing left to show.
		m.showEditor = false
		m.selectedDoc = nil
		m.editorSchema = nil
		m.dirty = false
		m.dirtyValues = nil
		m.focus = focusState{Target: FocusPane, PaneIndex: maxInt(len(m.panes)-1, 0)}
		m.rebuildPanes()
	} else {
		// Keep any open editor pointed at its (unrelated) doc across the re-query.
		m.refreshDocViews()
	}
	m.setStatus("deleted", false)
	return m, nil
}

// discardTwinStatusMessage maps a non-OK published-twin read to armDiscard's
// status line. NotFound means there truly is no published twin — today's
// copy, byte-identical (D's plain delete-outright path applies). Any OTHER
// failure means the probe itself did not land — it must NOT be reported as
// "no published twin" (that would assert the twin is absent when we simply
// don't know, and D would delete the draft outright on a false premise), so
// it gets a distinct message naming WHICH failure: "network error, try again"
// was wrong copy for a refusal or a server fault.
func discardTwinStatusMessage(outcome apiclient.DocReadOutcome) string {
	if outcome == apiclient.DocReadNotFound {
		return "no published twin — D deletes the draft outright"
	}
	return "could not check published twin — " + outcome.Describe()
}

// armDiscard arms the R×2 discard confirm for doc — a DRAFT whose published
// twin exists. The twin probe (GetPerspectiveResult on the bare id) runs here
// at arm time because the server's discardDraft does NOT twin-guard:
// discarding the only draft deletes the document outright, which is D's job
// with its own confirm.
func (m *model) armDiscard(doc *Doc, typeName string) {
	if doc.Status != "draft" {
		m.setStatus("nothing to discard — not a draft", true)
		return
	}
	bare := strings.TrimPrefix(doc.ID, "drafts.")
	if _, outcome := m.ds.GetPerspectiveResult(typeName, bare, ""); outcome != apiclient.DocReadOK {
		m.setStatus(discardTwinStatusMessage(outcome), true)
		return
	}
	m.discardArmed = true
	m.discardDocID = bare
	m.discardDocType = typeName
	m.setStatusInfo(fmt.Sprintf("discard draft of %q, revert to published? press R again · esc cancel", doc.Title))
}

// performDiscard sends the discardDraft mutation ({"discardDraft":{"id":
// <bare>,"type":…}}, matching Content.discard_draft's bare-id contract),
// then re-queries and lands on the PUBLISHED doc — the surviving version is
// what the user reverts to, mirroring Studio's post-discard navigation.
func (m model) performDiscard(bareID, typeName string) (tea.Model, tea.Cmd) {
	if err := m.ds.DiscardDraft(typeName, bareID); err != nil {
		m.setStatus(fmt.Sprintf("discard failed: %v", err), true)
		return m, nil
	}
	m.rebuildPanes()
	m.selectAndOpenDoc(bareID, typeName)
	m.setStatus("draft discarded — showing published", false)
	return m, nil
}

// taskTarget resolves the doc the task quick-actions (c claim / x close)
// operate on: the highlighted row of a doc-list pane whose type is "task", or
// the open editor doc when the editor holds a task. nil everywhere else, so
// c/x stay inert outside task contexts.
func (m model) taskTarget() *Doc {
	if m.focus.Target == FocusEditor && m.selectedDoc != nil &&
		m.editorSchema != nil && m.editorSchema.Name == "task" {
		return m.selectedDoc
	}
	if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) {
		pane := m.panes[m.focus.PaneIndex]
		if pane.IsDocList && pane.Node != nil && pane.Node.TypeName == "task" &&
			pane.Cursor < len(pane.Items) {
			return pane.Items[pane.Cursor].Doc
		}
	}
	return nil
}

// claimTask claims the targeted task for this TUI's worker identity via the
// flat POST /v1/tasks/:doc_id/claim endpoint. On success the panes re-query
// (so the fresh doc carries the server's claim object — what closeTask reads
// the epoch from) and the status bar shows the fencing epoch; an ok:false
// envelope surfaces the server's reason string verbatim.
func (m *model) claimTask(doc *Doc) {
	epoch, notices, help, err := m.ds.TaskClaimN(doc.ID, m.workerID)
	if err != nil {
		m.setStatus(err.Error(), true)
		return
	}
	m.refreshDocViews()
	// The claim envelope carries advisory rail-awareness notices + the server's
	// help[] next-command templates (charter D18); the desk TUI used to drop both.
	// Fold them into the one-line status message so a blocker on the freshly-claimed
	// task and the primary next step are visible without leaving the desk.
	m.setStatus(fmt.Sprintf("claimed (epoch %d)", epoch)+taskAdvisorySuffix(notices, help), false)
}

// closeTask closes the targeted task via the flat POST /v1/tasks/:doc_id/close
// endpoint, echoing the claim-time fencing epoch read from the doc's claim
// object (Extra["claim"].epoch). An unclaimed task errors LOCALLY — the server
// would only fence it off anyway — and an ok:false envelope surfaces the
// server's reason verbatim (fenced_off, not_claimed, …).
func (m *model) closeTask(doc *Doc) {
	epoch, ok := doc.ClaimEpoch()
	if !ok {
		m.setStatus("not claimed — claim first (c)", true)
		return
	}
	notices, help, err := m.ds.TaskCloseN(doc.ID, m.workerID, epoch)
	if err != nil {
		m.setStatus(err.Error(), true)
		return
	}
	m.refreshDocViews()
	m.setStatus("closed"+taskAdvisorySuffix(notices, help), false)
}

// taskAdvisorySuffix builds the compact tail the desk TUI appends to a claim/
// close status line so the server's advisory notices + help[] templates are
// surfaced, not dropped (charter D18). It shows the highest-priority rail notice
// (blocked outranks rail_changed) and the PRIMARY help template (help[0] — the
// pulse line after a claim); the status line clips on width like any long
// message. Empty when the server sent neither.
func taskAdvisorySuffix(notices []apiclient.TaskNotice, help []string) string {
	var b strings.Builder
	if n, ok := topDeskNotice(notices); ok {
		switch n.Type {
		case "blocked_while_claimed":
			b.WriteString(" · blocked while claimed: " + n.TaskID)
		case "rail_changed":
			b.WriteString(" · rail changed: " + n.ParentID)
		}
	}
	for _, h := range help {
		if h != "" {
			b.WriteString(" · next: " + h)
			break
		}
	}
	return b.String()
}

// topDeskNotice mirrors taskboard.topNotice's priority (a blocked_while_claimed
// on your held task outranks a rail_changed) without importing the board's
// unexported picker. Returns false when neither known shape is present — an
// unknown future notice is ignored, never guessed.
func topDeskNotice(notices []apiclient.TaskNotice) (apiclient.TaskNotice, bool) {
	var rail *apiclient.TaskNotice
	for i := range notices {
		switch notices[i].Type {
		case "blocked_while_claimed":
			return notices[i], true
		case "rail_changed":
			if rail == nil {
				rail = &notices[i]
			}
		}
	}
	if rail != nil {
		return *rail, true
	}
	return apiclient.TaskNotice{}, false
}

// workerIdentity computes the desk TUI's task-claim worker id once per process.
// It DELEGATES to taskboard.CmuxWorkerID() — the one honored-everywhere
// derivation — so a cmux pane owns its task consistently: the same
// cmux-<CMUX_SURFACE_ID> id the `bp cmux` hook claims with, falling through to
// the historic tui-<hostname> convention outside cmux entirely. Previously this
// was a hand-copied clone that stopped at BARKPARK_WORKER_ID → tui-<hostname>,
// so a raw cmux pane (CMUX_SURFACE_ID set, BARKPARK_WORKER_ID unset) claimed via
// the hook as cmux-<surface> yet closed here as tui-<host> → 409 fenced_off.
func workerIdentity() string {
	return taskboard.CmuxWorkerID()
}

// setStatus stores a transient status-line message. isErr=true marks it an error
// (rendered red ✕); isErr=false marks it a success confirmation (rendered green
// ✓). For neutral notices and confirm prompts use setStatusInfo instead. The
// message is cleared by clearStatus on the next key action.
func (m *model) setStatus(msg string, isErr bool) {
	m.status = msg
	m.statusErr = isErr
	m.statusInfo = false
}

// setStatusInfo stores a neutral, non-alarming status message (rendered dim ·,
// never red) — an informational notice ("no matches", "never published") or a
// two-press confirm prompt. It is NOT a failure, so it must not render as an
// error. Cleared by clearStatus on the next key action.
func (m *model) setStatusInfo(msg string) {
	m.status = msg
	m.statusErr = false
	m.statusInfo = true
}

// clearStatus wipes any pending status message. Called at the top of each key
// action so a status line only lingers until the user's next keystroke.
func (m *model) clearStatus() {
	m.status = ""
	m.statusErr = false
	m.statusInfo = false
}
