package chathost

import (
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

// leasedTurn is a send_turn as Client.Commands decodes it: the references ride
// payload.attachments (StudioChat.TurnAttachments.to_references/1), and the
// lease is the one attachmentServer answers for.
func leasedTurn(t *testing.T, provider, cwd, content string, refs ...AttachmentRef) RemoteCommand {
	t.Helper()
	payload := map[string]any{"cwd": cwd, "content": content, "mode": "plan"}
	if len(refs) > 0 {
		list := make([]any, 0, len(refs))
		for _, ref := range refs {
			list = append(list, map[string]any{"id": ref.ID, "media_type": ref.MediaType, "byte_size": ref.ByteSize})
		}
		payload["attachments"] = list
	}
	raw, err := json.Marshal(map[string]any{
		"lease_id": "lease-1", "epoch": 1, "last_cursor": 0,
		"command": map[string]any{"provider": provider, "operation": "send_turn", "session_id": "session-images", "payload": payload},
	})
	if err != nil {
		t.Fatal(err)
	}
	var command RemoteCommand
	if err := json.Unmarshal(raw, &command); err != nil {
		t.Fatal(err)
	}
	return command
}

// installRecordingClaude puts a claude on PATH that writes the first line of
// its stdin, byte for byte, to the returned path and then ends the turn with a
// success result. The file exists only if claude was started.
func installRecordingClaude(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	framePath := filepath.Join(dir, "stdin-frame")
	binary, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	script := fmt.Sprintf("#!/bin/sh\nBARKPARK_CLAUDE_RECORD_STDIN=%q exec %q -test.run=TestClaudeRecordingHelperProcess -- \"$@\"\n", framePath, binary)
	if err := os.WriteFile(filepath.Join(dir, "claude"), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return framePath
}

func TestClaudeRecordingHelperProcess(t *testing.T) {
	framePath := os.Getenv("BARKPARK_CLAUDE_RECORD_STDIN")
	if framePath == "" {
		return
	}
	line, _ := bufio.NewReaderSize(os.Stdin, 1<<20).ReadBytes('\n')
	if err := os.WriteFile(framePath, line, 0o600); err != nil {
		os.Exit(4)
	}
	encoder := json.NewEncoder(os.Stdout)
	_ = encoder.Encode(map[string]any{"type": "system", "subtype": "init", "session_id": "claude-thread"})
	_ = encoder.Encode(map[string]any{"type": "result", "subtype": "success", "is_error": false})
	os.Exit(0)
}

// installTripwire puts a provider binary on PATH that leaves a marker file the
// moment it is started. The returned func reports whether it was.
func installTripwire(t *testing.T, provider string) func() bool {
	t.Helper()
	dir := t.TempDir()
	marker := filepath.Join(dir, "started")
	script := fmt.Sprintf("#!/bin/sh\n: > %q\nexit 1\n", marker)
	if err := os.WriteFile(filepath.Join(dir, provider), []byte(script), 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
	return func() bool {
		_, err := os.Stat(marker)
		return err == nil
	}
}

// runRecordedTurn runs one claude send_turn through a handler that fetches
// from the given images, and returns the stdin line claude received.
func runRecordedTurn(t *testing.T, content string, images ...[]byte) (string, []AttachmentRef) {
	t.Helper()
	bodies := map[string]string{}
	var refs []AttachmentRef
	for _, data := range images {
		ref := refFor(data, sniffImageType(data))
		bodies[ref.ID] = envelope(ref.ID, ref.MediaType, len(data), data)
		refs = append(refs, ref)
	}
	client, requests := attachmentServer(t, bodies)
	framePath := installRecordingClaude(t)
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.Images = client

	var events []map[string]any
	err := handler.Handle(context.Background(), leasedTurn(t, "claude", handler.ApprovedRoots[0], content, refs...),
		func(event map[string]any) error { events = append(events, event); return nil })
	if err != nil {
		t.Fatalf("Handle() = %v", err)
	}
	if last := events[len(events)-1]; last["kind"] != "turn_completed" {
		t.Fatalf("last event = %#v, want turn_completed", last)
	}
	if got := requests.Load(); got != int64(len(images)) {
		t.Fatalf("%d attachment requests, want %d", got, len(images))
	}
	frame, err := os.ReadFile(framePath)
	if err != nil {
		t.Fatalf("claude recorded no stdin frame: %v", err)
	}
	return string(frame), refs
}

// imageBlock is one image block exactly as json.Marshal writes it on claude's
// stdin (keys sorted).
func imageBlock(mediaType string, data []byte) string {
	return `{"source":{"data":"` + base64.StdEncoding.EncodeToString(data) + `","media_type":"` + mediaType + `","type":"base64"},"type":"image"}`
}

func userFrame(blocks ...string) string {
	return `{"message":{"content":[` + strings.Join(blocks, ",") + `],"role":"user"},"type":"user"}` + "\n"
}

// The criterion: one attachment becomes the text block plus one base64 image
// block, and the block's bytes hash to the reference id.
func TestClaudeSendTurnWritesFetchedImagesAsImageBlocks(t *testing.T) {
	image := pngBytes("a picture")
	frame, refs := runRecordedTurn(t, "what is in this picture?", image)

	want := userFrame(`{"text":"what is in this picture?","type":"text"}`, imageBlock("image/png", image))
	if frame != want {
		t.Fatalf("claude stdin frame\n got %s\nwant %s", frame, want)
	}

	var decoded struct {
		Message struct {
			Content []struct {
				Type   string `json:"type"`
				Source struct {
					Data string `json:"data"`
				} `json:"source"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal([]byte(frame), &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Message.Content) != 2 || decoded.Message.Content[1].Type != "image" {
		t.Fatalf("content = %#v, want a text block then an image block", decoded.Message.Content)
	}
	data, err := base64.StdEncoding.DecodeString(decoded.Message.Content[1].Source.Data)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(data)
	if hex.EncodeToString(sum[:]) != refs[0].ID {
		t.Fatalf("image block bytes hash to %x, the reference id is %s", sum, refs[0].ID)
	}
}

func TestClaudeSendTurnImageOnlyWritesNoTextBlock(t *testing.T) {
	image := []byte("GIF89a only a picture")
	frame, _ := runRecordedTurn(t, "", image)
	if want := userFrame(imageBlock("image/gif", image)); frame != want {
		t.Fatalf("claude stdin frame\n got %s\nwant %s", frame, want)
	}
}

func TestClaudeSendTurnWritesTwoImagesInReferenceOrder(t *testing.T) {
	first, second := []byte("\xFF\xD8\xFF first"), pngBytes("second")
	frame, _ := runRecordedTurn(t, "compare", first, second)
	want := userFrame(`{"text":"compare","type":"text"}`, imageBlock("image/jpeg", first), imageBlock("image/png", second))
	if frame != want {
		t.Fatalf("claude stdin frame\n got %s\nwant %s", frame, want)
	}
}

// Regression pin: a text-only turn writes the bytes it wrote before this
// change, and asks the server for nothing.
func TestClaudeTextOnlyTurnWritesTheSameStdinFrameAsBefore(t *testing.T) {
	frame, _ := runRecordedTurn(t, "prove it")
	const before = `{"message":{"content":[{"text":"prove it","type":"text"}],"role":"user"},"type":"user"}` + "\n"
	if frame != before {
		t.Fatalf("claude stdin frame\n got %s\nwant %s", frame, before)
	}
}

// failedImageTurn runs a claude send_turn whose one image the server answers
// with body (or a 404 when body is ""), and returns the handler's error.
func failedImageTurn(t *testing.T, image []byte, body string) (error, func() bool, int) {
	t.Helper()
	ref := refFor(image, "image/png")
	bodies := map[string]string{}
	if body != "" {
		bodies[ref.ID] = body
	}
	client, _ := attachmentServer(t, bodies)
	started := installTripwire(t, "claude")
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.Images = client
	emitted := 0
	err := handler.Handle(context.Background(), leasedTurn(t, "claude", handler.ApprovedRoots[0], "look", ref),
		func(map[string]any) error { emitted++; return nil })
	return err, started, emitted
}

func TestClaudeSendTurnFetchFailureNeverStartsClaude(t *testing.T) {
	err, started, emitted := failedImageTurn(t, pngBytes("gone"), "")
	if err == nil {
		t.Fatal("Handle() = nil for a turn whose image answers 404")
	}
	if started() {
		t.Fatal("claude was started although the image could not be fetched")
	}
	if emitted != 0 {
		t.Fatalf("the handler emitted %d events before failing; the runner's terminal event must be the only one", emitted)
	}
	for _, want := range []string{"could not fetch image 1 of 1", "404", "claude was not started"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not say %q", err, want)
		}
	}
	// The server's body is not repeated.
	if strings.Contains(err.Error(), "chat attachment not found") {
		t.Errorf("error %q repeats the response body", err)
	}
}

func TestClaudeSendTurnRefusedImageNeverStartsClaude(t *testing.T) {
	image, swapped := pngBytes("the referenced one"), pngBytes("another, same size")
	ref := refFor(image, "image/png")
	err, started, emitted := failedImageTurn(t, image, envelope(ref.ID, "image/png", len(swapped), swapped))
	if err == nil {
		t.Fatal("Handle() = nil for bytes that are not the referenced ones")
	}
	if started() || emitted != 0 {
		t.Fatalf("claude started=%v, events=%d; want neither", started(), emitted)
	}
	for _, want := range []string{"refused image 1 of 1", "sha256 of the bytes is not the id", "claude was not started"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not say %q", err, want)
		}
	}
	for _, leaked := range []string{string(swapped), base64.StdEncoding.EncodeToString(swapped), "another, same size"} {
		if strings.Contains(err.Error(), leaked) {
			t.Errorf("error text carries image bytes: %q", err)
		}
	}
}

func TestClaudeSendTurnWithImagesAndNoFetcherIsRefused(t *testing.T) {
	started := installTripwire(t, "claude")
	handler := NewLocalHandler([]string{t.TempDir()})
	err := handler.Handle(context.Background(), leasedTurn(t, "claude", handler.ApprovedRoots[0], "look", refFor(pngBytes("x"), "image/png")),
		func(map[string]any) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "no way to fetch") || started() {
		t.Fatalf("err=%v started=%v; want a refusal and no claude", err, started())
	}
}

func TestSendTurnBadImageReferenceNeverStartsClaude(t *testing.T) {
	started := installTripwire(t, "claude")
	client, requests := attachmentServer(t, nil)
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.Images = client
	bad := AttachmentRef{ID: "../../etc/passwd", MediaType: "image/png", ByteSize: 4}
	err := handler.Handle(context.Background(), leasedTurn(t, "claude", handler.ApprovedRoots[0], "look", bad),
		func(map[string]any) error { return nil })
	if err == nil || !strings.Contains(err.Error(), "refused the attachments of this turn") {
		t.Fatalf("err=%v; want the reference refused", err)
	}
	if started() || requests.Load() != 0 {
		t.Fatalf("claude started=%v, requests=%d; want neither", started(), requests.Load())
	}
}

// The runner turns the handler's error into the turn's one event: a terminal
// error that says what happened.
func TestRunnerPublishesOneTerminalErrorWhenAnImageCannotBeFetched(t *testing.T) {
	var mu sync.Mutex
	var published []map[string]any
	arrived := make(chan struct{}, 8)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		if r.URL.Path != "/v1/chat-host/events" {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"message":"chat attachment not found"}}`))
			return
		}
		var body struct {
			Event map[string]any `json:"event"`
		}
		raw, _ := io.ReadAll(r.Body)
		_ = json.Unmarshal(raw, &body)
		mu.Lock()
		published = append(published, body.Event)
		mu.Unlock()
		w.WriteHeader(http.StatusAccepted)
		_, _ = w.Write([]byte(`{"accepted":true}`))
		arrived <- struct{}{}
	}))
	defer server.Close()

	started := installTripwire(t, "claude")
	client := &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true}
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.Images = client
	runner := &Runner{Client: client, Handler: handler, active: make(map[string]activeCommand)}
	runner.start(context.Background(), leasedTurn(t, "claude", handler.ApprovedRoots[0], "look", refFor(pngBytes("gone"), "image/png")))

	select {
	case <-arrived:
	case <-time.After(10 * time.Second):
		t.Fatal("no event was published")
	}
	// The command's goroutine has ended once it leaves the active set; after
	// that nothing more can be published.
	deadline := time.Now().Add(10 * time.Second)
	for {
		runner.mu.Lock()
		running := len(runner.active)
		runner.mu.Unlock()
		if running == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the command never ended")
		}
		time.Sleep(5 * time.Millisecond)
	}

	mu.Lock()
	defer mu.Unlock()
	if len(published) != 1 {
		t.Fatalf("%d events published, want exactly one: %#v", len(published), published)
	}
	event := published[0]
	failure, _ := event["error"].(map[string]any)
	message, _ := failure["message"].(string)
	if event["kind"] != "terminal" || event["terminal_state"] != "error" || !strings.Contains(message, "could not fetch image 1 of 1") {
		t.Fatalf("event = %#v; want one terminal error that names the failed fetch", event)
	}
	if started() {
		t.Fatal("claude was started")
	}
}

func TestSendTurnEmptyContentWithoutAttachmentsIsStillRefused(t *testing.T) {
	for _, provider := range []string{"claude", "codex"} {
		started := installTripwire(t, provider)
		handler := NewLocalHandler([]string{t.TempDir()})
		err := handler.Handle(context.Background(), leasedTurn(t, provider, handler.ApprovedRoots[0], ""),
			func(map[string]any) error { return nil })
		if err == nil || err.Error() != "command requires cwd and content" {
			t.Fatalf("%s: err=%v; want the empty turn refused", provider, err)
		}
		if started() {
			t.Fatalf("%s was started for an empty turn", provider)
		}
	}
}

func TestCodexSendTurnWithAttachmentsIsRefused(t *testing.T) {
	image := pngBytes("for codex")
	ref := refFor(image, "image/png")
	client, requests := attachmentServer(t, map[string]string{ref.ID: envelope(ref.ID, "image/png", len(image), image)})
	started := installTripwire(t, "codex")
	handler := NewLocalHandler([]string{t.TempDir()})
	handler.Images = client
	emitted := 0
	err := handler.Handle(context.Background(), leasedTurn(t, "codex", handler.ApprovedRoots[0], "look", ref),
		func(map[string]any) error { emitted++; return nil })
	if err == nil || !strings.Contains(err.Error(), "codex on a registered host takes text only") {
		t.Fatalf("err=%v; want codex to refuse a turn with images", err)
	}
	if started() || emitted != 0 || requests.Load() != 0 {
		t.Fatalf("codex started=%v, events=%d, fetches=%d; want none", started(), emitted, requests.Load())
	}
}

// What the host advertises is what the fetch accepts: the four pictures, then
// the two file types.
func TestClaudeAttachmentTypesAreTheFetchableOnes(t *testing.T) {
	types := ClaudeAttachmentTypes()
	want := []string{"image/png", "image/jpeg", "image/gif", "image/webp", "text/plain", "application/pdf"}
	if strings.Join(types, ",") != strings.Join(want, ",") {
		t.Fatalf("advertised %v, want %v", types, want)
	}
	for _, mediaType := range types {
		if !acceptedMediaType(mediaType) {
			t.Errorf("%s is advertised but the fetch refuses it", mediaType)
		}
	}
	for _, mediaType := range ClaudeImageTypes() {
		if !isImageMediaType(mediaType) {
			t.Errorf("%s is handed to claude as an image block but is not a picture type", mediaType)
		}
	}
}
