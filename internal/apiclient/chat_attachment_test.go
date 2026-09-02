package apiclient

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

// The chat attachment bindings (ct-bl-chat-attachments, charter D16).
//
// The failure mode these pin: an attachment binding that reaches for the media
// plugin. `GET /media/files/*` is any-token-public, so a chat attachment served
// through it is readable by a token class that cannot reach the conversation.
// Every test here therefore asserts the PATH as hard as it asserts the payload —
// a binding that silently retargeted /media/upload would still round-trip bytes
// against a permissive fake, and would still be the bug.

var attachmentBytes = []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3}

const attachmentID = "497790947d4666760ce38f3c00e852c71fdb66cae849bae8e9ede352719e1581"

func TestUploadChatAttachmentPostsBase64ToTheChatOwnedRoute(t *testing.T) {
	var gotPath, gotMethod string
	var gotBody map[string]any

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		gotPath, gotMethod = r.URL.Path, r.Method
		_ = json.NewDecoder(r.Body).Decode(&gotBody)
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"attachment":{"id":"`+attachmentID+`","media_type":"image/png","byte_size":11,"url":"/v1/chat/sessions/s1/attachments/`+attachmentID+`"}}`)
	}))
	defer srv.Close()

	att, err := newChatClient(srv.URL).UploadChatAttachment("s1", attachmentBytes)
	if err != nil {
		t.Fatalf("UploadChatAttachment: %v", err)
	}

	if gotMethod != http.MethodPost || gotPath != "/v1/chat/sessions/s1/attachments" {
		t.Errorf("got %s %s, want POST /v1/chat/sessions/s1/attachments", gotMethod, gotPath)
	}
	if strings.Contains(gotPath, "/media") {
		t.Errorf("attachment upload reached a media route (%q) — charter D16 forbids it", gotPath)
	}
	if got, _ := gotBody["data"].(string); got != base64.StdEncoding.EncodeToString(attachmentBytes) {
		t.Errorf("data = %q, want the base64 of the uploaded bytes", got)
	}
	// The body is EXACTLY {data} — a client-declared media type is not part of
	// the contract (the server sniffs), so sending one would be drift.
	if len(gotBody) != 1 {
		t.Errorf("upload body = %v, want exactly one key (data)", gotBody)
	}

	if att.ID != attachmentID || att.MediaType != "image/png" || att.ByteSize != 11 {
		t.Errorf("reference = %+v, want the server's id/media_type/byte_size", att)
	}
	if att.Data != "" {
		t.Errorf("an upload ack must carry no bytes; got %d chars of data", len(att.Data))
	}
}

func TestGetChatAttachmentReadsBytesBackFromTheChatOwnedRoute(t *testing.T) {
	var gotPath string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		wantBearer(t, r)
		gotPath = r.URL.Path
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"attachment":{"id":"`+attachmentID+`","media_type":"image/png","byte_size":11,"data":"`+base64.StdEncoding.EncodeToString(attachmentBytes)+`"}}`)
	}))
	defer srv.Close()

	att, err := newChatClient(srv.URL).GetChatAttachment("s1", attachmentID)
	if err != nil {
		t.Fatalf("GetChatAttachment: %v", err)
	}
	if want := "/v1/chat/sessions/s1/attachments/" + attachmentID; gotPath != want {
		t.Errorf("path = %q, want %q", gotPath, want)
	}

	got, err := att.Bytes()
	if err != nil {
		t.Fatalf("Bytes: %v", err)
	}
	if string(got) != string(attachmentBytes) {
		t.Errorf("Bytes() = %v, want the uploaded payload %v", got, attachmentBytes)
	}
}

func TestChatAttachmentSurfacesTheServerRefusal(t *testing.T) {
	for _, tc := range []struct {
		name   string
		status int
		body   string
	}{
		{"cross-tenant 404", http.StatusNotFound, `{"error":{"code":"not_found","message":"chat session not found"}}`},
		{"plain data-plane 403", http.StatusForbidden, `{"error":{"code":"forbidden","message":"forbidden"}}`},
		{"oversize 400", http.StatusBadRequest, `{"error":{"code":"invalid_request","message":"attachment exceeds 3000000 bytes"}}`},
	} {
		t.Run(tc.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				w.Header().Set("Content-Type", "application/json")
				w.WriteHeader(tc.status)
				_, _ = io.WriteString(w, tc.body)
			}))
			defer srv.Close()

			if _, err := newChatClient(srv.URL).GetChatAttachment("s1", attachmentID); err == nil {
				t.Fatal("a server refusal must surface as an error, never a zero-valued attachment")
			}
		})
	}
}

// A 2xx whose envelope carries no id must not read as a working upload — a
// zero-valued reference would be indistinguishable from success at every later
// call site, which is exactly how a silent transport regression survives.
func TestChatAttachmentRejectsAnIdlessEnvelope(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = io.WriteString(w, `{"attachment":{}}`)
	}))
	defer srv.Close()

	if _, err := newChatClient(srv.URL).UploadChatAttachment("s1", attachmentBytes); err == nil {
		t.Fatal("an envelope with no id must be an error")
	}
}

// The transcript decode leg: a message row carries the reference as a SIBLING of
// metadata, and the raw store pointer is not in metadata at all.
func TestChatMessageDecodesTheAttachmentReference(t *testing.T) {
	raw := `{"seq":1,"role":"user","source_markdown":"look",
	         "metadata":{"origin":"api"},
	         "attachments":[{"id":"` + attachmentID + `","media_type":"image/png","byte_size":11,
	                         "url":"/v1/chat/sessions/s1/attachments/` + attachmentID + `"}]}`

	var m ChatMessage
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(m.Attachments) != 1 {
		t.Fatalf("Attachments = %v, want one reference", m.Attachments)
	}
	a := m.Attachments[0]
	if a.ID != attachmentID || a.MediaType != "image/png" || a.ByteSize != 11 {
		t.Errorf("reference = %+v, want the server's shape", a)
	}
	if a.Data != "" {
		t.Error("a transcript reference must never carry bytes")
	}
	if _, ok := m.Metadata["attachments"]; ok {
		t.Error("the raw store pointer must be lifted out of metadata by the server")
	}
}
