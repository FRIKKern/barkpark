package main

import (
	"strings"
	"testing"
)

// An empty doc-list pane must never render blank. The focused pane advertises
// the create key; the preview pane states the fact without it (it can't create).
func TestEmptyDocListInterior(t *testing.T) {
	focused := strings.Join(emptyDocListInterior(true), "\n")
	if !strings.Contains(focused, "No documents yet") {
		t.Errorf("focused empty state should name the condition:\n%s", focused)
	}
	if !strings.Contains(focused, "n") || !strings.Contains(focused, "create") {
		t.Errorf("focused empty state should advertise the create key:\n%s", focused)
	}

	preview := strings.Join(emptyDocListInterior(false), "\n")
	if !strings.Contains(preview, "No documents yet") {
		t.Errorf("preview empty state should name the condition:\n%s", preview)
	}
	if strings.Contains(preview, "create") {
		t.Errorf("preview empty state must not advertise a create key it can't offer:\n%s", preview)
	}
}
