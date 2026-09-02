package chat

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// The TUI's half of the ONE attachment reference shape (ct-bl-chat-attachments).
//
// The rendering leg is the criterion's "render the same reference shape without
// embedding local paths, bearer tokens, or raw bytes in the transcript" — so the
// assertions are about what the chip does NOT say as much as what it does.

const testAttachmentID = "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581"

func TestRenderUserRowDrawsAttachmentChipsFromTheReference(t *testing.T) {
	msg := Message{
		Seq:            1,
		Role:           "user",
		SourceMarkdown: "look at this",
		Attachments: []Attachment{
			{ID: testAttachmentID, MediaType: "image/png", ByteSize: 2048,
				URL: "/v1/chat/sessions/s1/attachments/" + testAttachmentID},
			{ID: "b" + testAttachmentID[1:], MediaType: "image/gif", ByteSize: 15},
		},
	}

	out := strings.Join(renderMessage(80, msg, false, ""), "\n")

	if !strings.Contains(out, "look at this") {
		t.Errorf("the prompt echo went missing:\n%s", out)
	}
	if !strings.Contains(out, "image/png") || !strings.Contains(out, "2.0 KB") {
		t.Errorf("the png chip is missing its type/size:\n%s", out)
	}
	if !strings.Contains(out, "image/gif") || !strings.Contains(out, "15 B") {
		t.Errorf("the gif chip is missing its type/size:\n%s", out)
	}

	// The whole point: the chip renders the reference, not a locator. A url, an
	// id, or (worst) a local path in the transcript is the defect.
	for _, forbidden := range []string{"/v1/chat/sessions", testAttachmentID, "http"} {
		if strings.Contains(out, forbidden) {
			t.Errorf("the transcript leaked %q:\n%s", forbidden, out)
		}
	}
}

func TestRenderUserRowIsUnchangedWithoutAttachments(t *testing.T) {
	plain := Message{Seq: 1, Role: "user", SourceMarkdown: "just words"}

	got := renderMessage(80, plain, false, "")
	want := renderUserEcho(bodyWidth(80), "just words")

	if len(got) != len(want) {
		t.Fatalf("an attachment-free row changed shape: got %d lines, want %d", len(got), len(want))
	}
	for i := range got {
		if got[i] != want[i] {
			t.Errorf("line %d: got %q, want %q", i, got[i], want[i])
		}
	}
}

func TestHumanBytes(t *testing.T) {
	for _, tc := range []struct {
		n    int
		want string
	}{{0, "0 B"}, {999, "999 B"}, {1024, "1.0 KB"}, {1536, "1.5 KB"}, {1 << 20, "1.0 MB"}} {
		if got := humanBytes(tc.n); got != tc.want {
			t.Errorf("humanBytes(%d) = %q, want %q", tc.n, got, tc.want)
		}
	}
}

// The transport seam: UploadAttachment reads the LOCAL path and hands the bytes
// to the wire client — and the path stays local. A missing file is an honest
// error, never a silent empty upload.
func TestClientTransportUploadAttachmentReadsTheLocalFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "shot.png")
	payload := []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 9, 9}
	if err := os.WriteFile(path, payload, 0o600); err != nil {
		t.Fatal(err)
	}

	tr := NewHTTPTransport(Config{BaseURL: "http://127.0.0.1:1", Token: "tok"})

	// The read succeeds and the POST fails (nothing is listening) — which is the
	// discrimination that matters: a file-read regression would surface as the
	// os error instead, and this asserts it does not.
	_, err := tr.UploadAttachment("s1", path)
	if err == nil {
		t.Fatal("expected the unreachable POST to error")
	}
	if os.IsNotExist(err) {
		t.Fatalf("the local file was not read: %v", err)
	}

	if _, err := tr.UploadAttachment("s1", filepath.Join(dir, "absent.png")); !os.IsNotExist(err) {
		t.Errorf("a missing local file must surface as a not-exist error; got %v", err)
	}
}
