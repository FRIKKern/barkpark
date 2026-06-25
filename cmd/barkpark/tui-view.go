package main

import (
	"fmt"
	"strings"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"
)

// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  VIEW                                                                   ║
// ╚══════════════════════════════════════════════════════════════════════════╝

func (m model) View() string {
	if m.width == 0 {
		return "Loading..."
	}

	// Terminal too small on EITHER axis: emit a single truncated line so the
	// frame can never exceed m.height OR m.width. The vertical floor is 5 (the
	// smallest bounded frame is ph(1) + 2 border + 2 bars); the horizontal floor
	// is minFrameWidth (below it no usable column survives). One combined guard.
	if m.height < 5 || m.width < minFrameWidth {
		return clampLine(truncate("terminal too small", m.width), m.width)
	}

	toolbar := m.renderToolbar()
	helpBar := m.renderHelpBar()
	ph := m.paneHeight()

	plan := m.computeLayout()

	// Render columns against the planned budget. The summed physical width of the
	// returned columns equals m.width, so the JoinHorizontal body is EXACTLY
	// m.width — the toolbar/helpbar are never padded past the terminal.
	var columns []string
	if plan.collapsed {
		// Single full-width column following focus.
		if plan.showListPanes && plan.startPane < len(m.panes) {
			isActive := m.focus.Target == FocusPane && plan.startPane == m.focus.PaneIndex
			columns = append(columns, m.renderPane(m.panes[plan.startPane], plan.listWidth, ph, isActive))
		} else if m.showEditor {
			isActive := m.focus.Target == FocusEditor
			columns = append(columns, m.renderEditor(plan.editorWidth, ph, isActive))
		} else if preview := m.renderPreview(plan.editorWidth, ph); preview != "" {
			columns = append(columns, preview)
		} else {
			columns = append(columns, m.renderEmptyState(plan.editorWidth, ph))
		}
	} else {
		// Multi-pane (Miller columns): list windows + editor/preview/empty.
		for i := plan.startPane; i < len(m.panes); i++ {
			isActive := m.focus.Target == FocusPane && i == m.focus.PaneIndex
			columns = append(columns, m.renderPane(m.panes[i], plan.listWidth, ph, isActive))
		}
		if m.showEditor {
			isActive := m.focus.Target == FocusEditor
			columns = append(columns, m.renderEditor(plan.editorWidth, ph, isActive))
		} else if preview := m.renderPreview(plan.editorWidth, ph); preview != "" {
			columns = append(columns, preview)
		} else {
			columns = append(columns, m.renderEmptyState(plan.editorWidth, ph))
		}
	}

	var body string
	switch {
	case m.selector.active:
		// Replace the column body with the centred scope-selector modal.
		body = m.renderSelector(m.width, ph)
	case m.refPicker.active:
		body = m.renderRefPicker(m.width, ph)
	case m.searchOpen:
		body = m.renderSearchResults(m.width, ph)
	case m.diffOpen:
		body = m.renderDiffView(m.width, ph)
	case m.historyOpen:
		body = m.renderHistoryView(m.width, ph)
	case m.helpOpen:
		body = m.renderHelpOverlay(m.width, ph)
	default:
		body = lipgloss.JoinHorizontal(lipgloss.Top, columns...)
	}

	// Per-line width backstop: clamp every body row to m.width. computeLayout
	// already keeps the sum at m.width, but this guarantees no row can overflow
	// horizontally even in odd transient states (mid-resize, modal, rounding).
	body = clampBlock(body, m.width)

	frame := lipgloss.JoinVertical(lipgloss.Left, toolbar, body, helpBar)
	return clampBlock(frame, m.width)
}

// clampLine truncates a single line to at most w display columns (ANSI/width
// aware, no ellipsis — the caller chooses the message). Never widens.
func clampLine(s string, w int) string {
	if w < 0 {
		w = 0
	}
	return ansi.Truncate(s, w, "")
}

// clampBlock applies clampLine to every line of a multi-line block. The
// horizontal safety net: nothing the body emits can exceed m.width.
func clampBlock(s string, w int) string {
	lines := strings.Split(s, "\n")
	for i, ln := range lines {
		if lipgloss.Width(ln) > w {
			lines[i] = clampLine(ln, w)
		}
	}
	return strings.Join(lines, "\n")
}

// clampItemLines flattens a list-item's rendered lines into line-accurate,
// width-bounded physical rows: any embedded newline (lipgloss soft-wrap) is
// split out and every resulting segment is hard-truncated to w columns. This
// keeps renderListInterior's per-item row count truthful so the window can never
// overflow the box height, and keeps each row within the column width.
func clampItemLines(il []string, w int) []string {
	var out []string
	for _, seg := range il {
		for _, line := range strings.Split(seg, "\n") {
			if lipgloss.Width(line) > w {
				line = clampLine(line, w)
			}
			out = append(out, line)
		}
	}
	return out
}

// ── Toolbar ──────────────────────────────────────────────────────────────────

func (m model) renderToolbar() string {
	logo := logoStyle.Render("▣ Studio")
	tabs := dimStyle.Render("[") +
		activeTabStyle.Render("Structure") +
		dimStyle.Render("] ") +
		dimStyle.Render("Vision")
	prefix := logo + "  " + tabs // highest-value left segment — kept longest

	// Breadcrumbs (the elastic, lowest-priority left segment).
	crumbs := make([]string, 0, len(m.panes)+1)
	for _, p := range m.panes {
		crumbs = append(crumbs, p.Node.Title)
	}
	if m.selectedDoc != nil {
		crumbs = append(crumbs, m.selectedDoc.Title)
	}

	var bc string
	for i, c := range crumbs {
		if i > 0 {
			bc += dimStyle.Render(" > ")
		}
		if i == len(crumbs)-1 {
			bc += breadcrumbActiveStyle.Render(truncate(c, 20))
		} else {
			bc += breadcrumbStyle.Render(truncate(c, 14))
		}
	}

	scope := fmt.Sprintf("%s/%s/%s", m.ds.Workspace, m.ds.Project, m.ds.Dataset)
	right := breadcrumbStyle.Render("⌗ "+scope) + dimStyle.Render("  s switch")

	// Assemble with graceful degradation so the content always fits on ONE line
	// of width m.width — lipgloss soft-wraps any content wider than the style
	// width, which would steal extra rows from the body budget (ph = h-4).
	//
	// Tier 1: prefix + breadcrumb + gap + right (full)
	// Tier 2: prefix + gap + right            (drop breadcrumb)
	// Tier 3: prefix + gap + "s switch"       (drop scope, keep switch hint)
	// Tier 4: ansi.Truncate(prefix+breadcrumb, m.width)  (no room for the right rail)
	// Backstop: ansi.Truncate the chosen line to m.width with an ellipsis.
	const minGap = 2 // breathing room between left and right rails
	rightW := lipgloss.Width(right)
	switchOnly := dimStyle.Render("s switch")
	switchW := lipgloss.Width(switchOnly)

	var content string
	switch {
	case lipgloss.Width(prefix)+lipgloss.Width("  "+bc)+minGap+rightW <= m.width:
		// Tier 1 — everything fits.
		left := prefix + "  " + bc
		gap := m.width - lipgloss.Width(left) - rightW
		content = left + strings.Repeat(" ", gap) + right
	case lipgloss.Width(prefix)+minGap+rightW <= m.width:
		// Tier 2 — drop the breadcrumb, keep prefix + full right rail.
		gap := m.width - lipgloss.Width(prefix) - rightW
		content = prefix + strings.Repeat(" ", gap) + right
	case lipgloss.Width(prefix)+minGap+switchW <= m.width:
		// Tier 3 — drop the scope, keep prefix + the "s switch" affordance.
		gap := m.width - lipgloss.Width(prefix) - switchW
		content = prefix + strings.Repeat(" ", gap) + switchOnly
	default:
		// Tier 4 — no room for any right rail; show as much of the left as fits.
		content = prefix + "  " + bc
	}

	// Hard backstop: clamp to exactly m.width display columns (ANSI/width-aware,
	// ellipsis tail). Guarantees one physical line ≤ m.width even at width=20.
	content = ansi.Truncate(content, m.width, "…")
	return toolbarStyle.Width(m.width).MaxHeight(1).Render(content)
}

// ── Help bar ─────────────────────────────────────────────────────────────────

func (m model) renderHelpBar() string {
	// New-document title prompt takes over the bar (vim-command-line style):
	// the one-line input lives HERE, in the chrome row, not in a pane.
	if m.creating {
		prompt := dimStyle.Render(" Title for new "+m.creatingTypeTitle()+": ") + m.textInput.View()
		prompt = ansi.Truncate(prompt, m.width, "…")
		return toolbarStyle.Width(m.width).MaxHeight(1).Render(prompt)
	}

	// Search query prompt — same vim-command-line takeover as the n-prompt.
	if m.searching {
		prompt := dimStyle.Render(" Search: ") + m.textInput.View()
		prompt = ansi.Truncate(prompt, m.width, "…")
		return toolbarStyle.Width(m.width).MaxHeight(1).Render(prompt)
	}

	// A pending status message takes over the bar — a failed save (red) or a
	// "saved" confirmation (green) must be impossible to miss.
	if m.status != "" {
		style := statusPublished // green = ok
		prefix := "✓ "
		if m.statusErr {
			style = statusDraft // amber/red = error
			prefix = "✕ "
		}
		styled := style.Bold(true).Render(" " + prefix + m.status)
		// Clamp the styled line to one physical row ≤ m.width (ANSI/width-aware)
		// so a long status can never soft-wrap and steal a body row.
		styled = ansi.Truncate(styled, m.width, "…")
		return toolbarStyle.Width(m.width).MaxHeight(1).Render(styled)
	}

	var help string
	if m.selector.active {
		help = " tab/j/k move  enter next/apply  ctrl+s apply  esc cancel"
	} else if m.refPicker.active {
		help = " j/k move  enter select  esc cancel"
	} else if m.searchOpen {
		help = " j/k move  enter open  esc dismiss"
	} else if m.editing && m.editingMultiline {
		help = " type to edit  enter newline  ctrl+s confirm  esc cancel"
	} else if m.editing {
		help = " type to edit  enter confirm  esc cancel"
	} else if m.focus.Target == FocusEditor && m.isCurrentPaper() {
		help = " j/k scroll  ctrl+d/u half-page  g/G top/bottom  read-only  esc back"
	} else if m.focus.Target == FocusEditor {
		if m.editorSchema != nil && m.editorSchema.Name == "task" {
			// Editor holding a task: the c/x quick actions work here too (see
			// taskTarget) — advertise them where they apply, like the task list does.
			help = " j/k fields  enter edit  ctrl+s save  c claim  x close  y dup  esc back"
		} else {
			help = " j/k fields  enter edit  space toggle  ctrl+s save  ctrl+p publish  U unpub  d diff  H hist  R discard  y dup  s scope  ? keys  esc back"
		}
	} else if m.focus.Target == FocusPane && m.focus.PaneIndex < len(m.panes) &&
		m.panes[m.focus.PaneIndex].IsDocList {
		if node := m.panes[m.focus.PaneIndex].Node; node != nil && node.TypeName == "task" {
			// Task list: the quick-action verbs lead — claim/close at terminal speed.
			help = " j/k navigate  c claim  x close  y dup  D delete  n new  / search  enter select  esc back"
		} else if len(m.marked) > 0 {
			// Marks present: the bulk verbs lead (Studio's floating action bar).
			help = fmt.Sprintf(" %d marked  space mark  ctrl+p publish marked  U unpub marked  esc clear", len(m.marked))
		} else {
			// Doc-list pane: surface the n-new / D-delete affordances, subtle, in hint order.
			help = " j/k navigate  space mark  n new  y dup  R discard  D delete  / search  enter select  s scope  ? keys  esc back  q quit"
		}
	} else {
		help = " j/k navigate  / search  h/l switch pane  enter select  s scope  ? keys  esc back  q quit"
	}
	// Clamp to one physical row ≤ m.width before styling so the bar never
	// soft-wraps at narrow widths; a shorter/elided help string is fine.
	styled := ansi.Truncate(dimStyle.Render(help), m.width, "…")
	return toolbarStyle.Width(m.width).MaxHeight(1).Render(styled)
}
