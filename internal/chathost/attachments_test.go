package chathost

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

var pngMagic = []byte{0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A}

func pngBytes(tail string) []byte { return append(append([]byte{}, pngMagic...), tail...) }

func refFor(data []byte, mediaType string) AttachmentRef {
	sum := sha256.Sum256(data)
	return AttachmentRef{ID: hex.EncodeToString(sum[:]), MediaType: mediaType, ByteSize: len(data)}
}

func envelope(id, mediaType string, byteSize int, data []byte) string {
	body, _ := json.Marshal(map[string]any{"attachment": map[string]any{
		"id": id, "media_type": mediaType, "byte_size": byteSize,
		"data": base64.StdEncoding.EncodeToString(data),
	}})
	return string(body)
}

// attachmentServer answers every attachment read with the body chosen per
// attachment id, and counts the requests it saw.
func attachmentServer(t *testing.T, bodies map[string]string) (*Client, *atomic.Int64) {
	t.Helper()
	var requests atomic.Int64
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests.Add(1)
		const prefix = "/v1/chat-host/leases/lease-1/attachments/"
		body, ok := bodies[strings.TrimPrefix(r.URL.Path, prefix)]
		if r.Method != http.MethodGet || !strings.HasPrefix(r.URL.Path, prefix) || !ok {
			w.WriteHeader(http.StatusNotFound)
			_, _ = w.Write([]byte(`{"error":{"message":"chat attachment not found"}}`))
			return
		}
		if got := r.Header.Get("Authorization"); got != "Host host-secret" {
			t.Errorf("Authorization=%q want the Host credential", got)
		}
		for name := range r.Header {
			switch name {
			case "Authorization", "User-Agent", "Accept-Encoding":
			default:
				t.Errorf("unexpected request header %s", name)
			}
		}
		if r.URL.RawQuery != "" || r.ContentLength > 0 {
			t.Errorf("attachment read carried a query or a body: %q, %d bytes", r.URL.RawQuery, r.ContentLength)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(body))
	}))
	t.Cleanup(server.Close)
	return &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true}, &requests
}

func wantRefused(t *testing.T, err error, fragment string) {
	t.Helper()
	var refused *AttachmentError
	if !errors.As(err, &refused) {
		t.Fatalf("got %v, want an *AttachmentError", err)
	}
	if !strings.Contains(err.Error(), fragment) {
		t.Fatalf("error %q does not name %q", err, fragment)
	}
	if Transient(err) {
		t.Fatalf("a refused attachment must not be transient: %v", err)
	}
}

func TestFetchAttachmentReturnsBytesThatMatchTheReference(t *testing.T) {
	cases := map[string][]byte{
		"image/png":  pngBytes("png body"),
		"image/jpeg": append([]byte{0xFF, 0xD8, 0xFF, 0xE0}, "jpeg body"...),
		"image/gif":  []byte("GIF89a gif body"),
		"image/webp": []byte("RIFF\x10\x00\x00\x00WEBPVP8 body"),
	}
	for mediaType, data := range cases {
		ref := refFor(data, mediaType)
		client, requests := attachmentServer(t, map[string]string{ref.ID: envelope(ref.ID, mediaType, len(data), data)})
		got, err := client.Attachment(context.Background(), "lease-1", ref)
		if err != nil {
			t.Fatalf("%s: %v", mediaType, err)
		}
		if got.ID != ref.ID || got.MediaType != mediaType || !bytes.Equal(got.Data, data) {
			t.Fatalf("%s: got id=%s type=%s %d bytes", mediaType, got.ID, got.MediaType, len(got.Data))
		}
		if requests.Load() != 1 {
			t.Fatalf("%s: %d requests, want 1", mediaType, requests.Load())
		}
	}
}

func TestFetchAttachmentRefusesBytesWhoseHashIsNotTheID(t *testing.T) {
	data := pngBytes("the picture the person sent")
	ref := refFor(data, "image/png")
	swapped := pngBytes("another one, the same length")[:len(data)]
	if len(swapped) != len(data) {
		t.Fatal("fixture: the swapped bytes must keep the length")
	}
	client, _ := attachmentServer(t, map[string]string{ref.ID: envelope(ref.ID, "image/png", len(swapped), swapped)})
	got, err := client.Attachment(context.Background(), "lease-1", ref)
	wantRefused(t, err, "sha256")
	if got.Data != nil {
		t.Fatal("refused bytes were returned")
	}
}

func TestFetchAttachmentRefusesBytesWhoseLengthIsNotTheByteSize(t *testing.T) {
	data := pngBytes("four more bytes than the reference says")
	sum := sha256.Sum256(data)
	// The id is the true hash of the served bytes, so only the length differs.
	ref := AttachmentRef{ID: hex.EncodeToString(sum[:]), MediaType: "image/png", ByteSize: len(data) - 4}
	client, _ := attachmentServer(t, map[string]string{ref.ID: envelope(ref.ID, "image/png", ref.ByteSize, data)})
	_, err := client.Attachment(context.Background(), "lease-1", ref)
	wantRefused(t, err, "bytes")
}

func TestFetchAttachmentRefusesAResponseOfAnotherMediaType(t *testing.T) {
	data := pngBytes("png")
	ref := refFor(data, "image/png")
	client, _ := attachmentServer(t, map[string]string{ref.ID: envelope(ref.ID, "image/jpeg", len(data), data)})
	_, err := client.Attachment(context.Background(), "lease-1", ref)
	wantRefused(t, err, "media type")
}

func TestFetchAttachmentRefusesAResponseForAnotherID(t *testing.T) {
	data := pngBytes("png")
	ref := refFor(data, "image/png")
	client, _ := attachmentServer(t, map[string]string{ref.ID: envelope(strings.Repeat("a", 64), "image/png", len(data), data)})
	_, err := client.Attachment(context.Background(), "lease-1", ref)
	wantRefused(t, err, "id")
}

func TestFetchAttachmentRefusesBytesThatAreNotThatImageType(t *testing.T) {
	// Hash, length and both declared types agree; only the bytes themselves say
	// otherwise.
	for _, data := range [][]byte{
		[]byte("<html><script>alert(1)</script></html>"),
		[]byte("GIF89a a gif declared as a png"),
	} {
		ref := refFor(data, "image/png")
		client, _ := attachmentServer(t, map[string]string{ref.ID: envelope(ref.ID, "image/png", len(data), data)})
		_, err := client.Attachment(context.Background(), "lease-1", ref)
		wantRefused(t, err, "not image/png")
	}
}

func TestFetchAttachmentRefusesDataThatIsNotBase64(t *testing.T) {
	data := pngBytes("png")
	ref := refFor(data, "image/png")
	body := `{"attachment":{"id":"` + ref.ID + `","media_type":"image/png","byte_size":11,"data":"***not base64***"}}`
	client, _ := attachmentServer(t, map[string]string{ref.ID: body})
	_, err := client.Attachment(context.Background(), "lease-1", ref)
	wantRefused(t, err, "base64")
}

// endlessBody serves JSON that never ends and counts what was read from it.
type endlessBody struct {
	read   atomic.Int64
	closed atomic.Bool
}

func (b *endlessBody) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = 'A'
	}
	if b.read.Load() == 0 && len(p) > 0 {
		copy(p, `{"attachment":{"data":"`)
	}
	b.read.Add(int64(len(p)))
	return len(p), nil
}

func (b *endlessBody) Close() error { b.closed.Store(true); return nil }

type roundTripFunc func(*http.Request) (*http.Response, error)

func (f roundTripFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

func TestFetchAttachmentStopsReadingPastTheCap(t *testing.T) {
	body := &endlessBody{}
	client := &Client{
		BaseURL:    "https://chat.example.test",
		Credential: "host-secret",
		HTTPClient: &http.Client{Transport: roundTripFunc(func(r *http.Request) (*http.Response, error) {
			return &http.Response{StatusCode: 200, Status: "200 OK", Header: http.Header{}, Body: body, Request: r}, nil
		})},
	}
	ref := refFor(pngBytes("png"), "image/png")
	_, err := client.Attachment(context.Background(), "lease-1", ref)
	wantRefused(t, err, "4500000")
	// One byte past the cap is what proves the body is over it.
	if got := body.read.Load(); got > MaxAttachmentResponseBytes+1 {
		t.Fatalf("read %d bytes of an endless body, want at most %d", got, MaxAttachmentResponseBytes+1)
	}
	if !body.closed.Load() {
		t.Fatal("the response body was left open")
	}
}

func TestFetchAttachmentAcceptsTheLargestStoredImageUnderTheCap(t *testing.T) {
	data := make([]byte, MaxAttachmentBytes)
	copy(data, pngMagic)
	ref := refFor(data, "image/png")
	body := envelope(ref.ID, "image/png", len(data), data)
	if len(body) > MaxAttachmentResponseBytes {
		t.Fatalf("a %d byte image answers with %d bytes, over the %d cap", len(data), len(body), MaxAttachmentResponseBytes)
	}
	client, _ := attachmentServer(t, map[string]string{ref.ID: body})
	got, err := client.Attachment(context.Background(), "lease-1", ref)
	if err != nil || len(got.Data) != MaxAttachmentBytes {
		t.Fatalf("got %d bytes, err=%v", len(got.Data), err)
	}
}

func TestFetchAttachmentRefusesABadReferenceWithoutARequest(t *testing.T) {
	good := refFor(pngBytes("png"), "image/png")
	bad := map[string]struct {
		lease string
		ref   AttachmentRef
	}{
		"short id":         {"lease-1", AttachmentRef{ID: good.ID[:63], MediaType: "image/png", ByteSize: 11}},
		"long id":          {"lease-1", AttachmentRef{ID: good.ID + "0", MediaType: "image/png", ByteSize: 11}},
		"uppercase id":     {"lease-1", AttachmentRef{ID: strings.ToUpper(good.ID), MediaType: "image/png", ByteSize: 11}},
		"path in id":       {"lease-1", AttachmentRef{ID: "../../../v1/chat-host/commands" + good.ID[:34], MediaType: "image/png", ByteSize: 11}},
		"query in id":      {"lease-1", AttachmentRef{ID: good.ID[:60] + "?a=b", MediaType: "image/png", ByteSize: 11}},
		"non-hex id":       {"lease-1", AttachmentRef{ID: strings.Repeat("g", 64), MediaType: "image/png", ByteSize: 11}},
		"svg":              {"lease-1", AttachmentRef{ID: good.ID, MediaType: "image/svg+xml", ByteSize: 11}},
		"empty media type": {"lease-1", AttachmentRef{ID: good.ID, MediaType: "", ByteSize: 11}},
		"zero bytes":       {"lease-1", AttachmentRef{ID: good.ID, MediaType: "image/png", ByteSize: 0}},
		"over the store":   {"lease-1", AttachmentRef{ID: good.ID, MediaType: "image/png", ByteSize: MaxAttachmentBytes + 1}},
		"empty lease":      {"", good},
		"path in lease":    {"../leases/lease-1", good},
		"query in lease":   {"lease-1?x=1", good},
	}
	for name, c := range bad {
		client, requests := attachmentServer(t, nil)
		_, err := client.Attachment(context.Background(), c.lease, c.ref)
		var refused *AttachmentError
		if !errors.As(err, &refused) || Transient(err) {
			t.Fatalf("%s: got %v, want a non-transient *AttachmentError", name, err)
		}
		if requests.Load() != 0 {
			t.Fatalf("%s: %d requests were made for a refused reference", name, requests.Load())
		}
	}
}

func TestFetchAttachmentNotFoundIsNotTransient(t *testing.T) {
	ref := refFor(pngBytes("png"), "image/png")
	client, requests := attachmentServer(t, nil)
	_, err := client.Attachment(context.Background(), "lease-1", ref)
	var status *StatusError
	if !errors.As(err, &status) || status.Code != http.StatusNotFound {
		t.Fatalf("got %v, want a 404 StatusError", err)
	}
	if Transient(err) {
		t.Fatal("a 404 must not be retried: the lease is over or the attachment is not this session's")
	}
	if requests.Load() != 1 {
		t.Fatalf("%d requests, want 1", requests.Load())
	}
}

func TestFetchAttachmentServerErrorIsTransient(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusBadGateway)
	}))
	defer server.Close()
	client := &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true}
	_, err := client.Attachment(context.Background(), "lease-1", refFor(pngBytes("png"), "image/png"))
	var status *StatusError
	if !errors.As(err, &status) || status.Code != http.StatusBadGateway || !Transient(err) {
		t.Fatalf("got %v, want a transient 502 StatusError", err)
	}
}

func TestFetchAttachmentUnauthorizedIsRevocation(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
	}))
	defer server.Close()
	client := &Client{BaseURL: server.URL, Credential: "host-secret", HTTPClient: server.Client(), AllowInsecureLoopback: true}
	_, err := client.Attachment(context.Background(), "lease-1", refFor(pngBytes("png"), "image/png"))
	if !errors.Is(err, ErrRevoked) {
		t.Fatalf("got %v want ErrRevoked", err)
	}
}

// commandWith decodes a leased command the way Client.Commands does, so the
// references carry the JSON decoder's own types.
func commandWith(t *testing.T, attachments string) RemoteCommand {
	t.Helper()
	var command RemoteCommand
	raw := `{"lease_id":"lease-1","epoch":1,"command":{"kind":"send_turn","content":"look"` + attachments + `}}`
	if err := json.Unmarshal([]byte(raw), &command); err != nil {
		t.Fatal(err)
	}
	return command
}

func refJSON(ref AttachmentRef) string {
	body, _ := json.Marshal(map[string]any{"id": ref.ID, "media_type": ref.MediaType, "byte_size": ref.ByteSize})
	return string(body)
}

func TestSendTurnAttachmentsAreFetchedInOrder(t *testing.T) {
	first, second := pngBytes("first"), []byte("GIF89a second")
	a, b := refFor(first, "image/png"), refFor(second, "image/gif")
	client, requests := attachmentServer(t, map[string]string{
		a.ID: envelope(a.ID, "image/png", len(first), first),
		b.ID: envelope(b.ID, "image/gif", len(second), second),
	})
	got, err := client.Attachments(context.Background(), commandWith(t, `,"attachments":[`+refJSON(b)+`,`+refJSON(a)+`]`))
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || !bytes.Equal(got[0].Data, second) || !bytes.Equal(got[1].Data, first) || got[0].MediaType != "image/gif" {
		t.Fatalf("got %d attachments out of order or wrong", len(got))
	}
	if requests.Load() != 2 {
		t.Fatalf("%d requests, want 2", requests.Load())
	}
}

func TestSendTurnWithoutAttachmentsFetchesNothing(t *testing.T) {
	client, requests := attachmentServer(t, nil)
	for _, attachments := range []string{``, `,"attachments":[]`} {
		got, err := client.Attachments(context.Background(), commandWith(t, attachments))
		if err != nil || len(got) != 0 {
			t.Fatalf("%q: got %d attachments, err=%v", attachments, len(got), err)
		}
	}
	if requests.Load() != 0 {
		t.Fatalf("%d requests for a turn with no attachments", requests.Load())
	}
}

func TestSendTurnReturnsNoAttachmentsWhenOneFails(t *testing.T) {
	first, second := pngBytes("first"), pngBytes("second")
	a, b := refFor(first, "image/png"), refFor(second, "image/png")
	// The second reference is not in the store: a 404.
	client, _ := attachmentServer(t, map[string]string{a.ID: envelope(a.ID, "image/png", len(first), first)})
	got, err := client.Attachments(context.Background(), commandWith(t, `,"attachments":[`+refJSON(a)+`,`+refJSON(b)+`]`))
	if err == nil || Transient(err) {
		t.Fatalf("got err=%v, want the non-transient 404", err)
	}
	if got != nil {
		t.Fatalf("a failed turn returned %d attachments, want none", len(got))
	}
}

func TestSendTurnRefusesMoreThanFourAttachments(t *testing.T) {
	bodies := map[string]string{}
	var refs []string
	for _, tail := range []string{"1", "2", "3", "4", "5"} {
		data := pngBytes(tail)
		ref := refFor(data, "image/png")
		bodies[ref.ID] = envelope(ref.ID, "image/png", len(data), data)
		refs = append(refs, refJSON(ref))
	}
	client, requests := attachmentServer(t, bodies)

	four, err := client.Attachments(context.Background(), commandWith(t, `,"attachments":[`+strings.Join(refs[:4], ",")+`]`))
	if err != nil || len(four) != 4 {
		t.Fatalf("four attachments: got %d, err=%v", len(four), err)
	}
	requests.Store(0)

	got, err := client.Attachments(context.Background(), commandWith(t, `,"attachments":[`+strings.Join(refs, ",")+`]`))
	wantRefused(t, err, "at most 4")
	if got != nil || requests.Load() != 0 {
		t.Fatalf("five attachments: %d returned, %d requests; want none of either", len(got), requests.Load())
	}
}

func TestSendTurnRefusesAMalformedAttachmentReference(t *testing.T) {
	data := pngBytes("png")
	good := refFor(data, "image/png")
	id := `"id":"` + good.ID + `"`
	malformed := map[string]string{
		"not a list":          `{"0":` + refJSON(good) + `}`,
		"null":                `null`,
		"string entry":        `["` + good.ID + `"]`,
		"null entry":          `[null]`,
		"extra key":           `[{` + id + `,"media_type":"image/png","byte_size":11,"name":"../../etc/passwd"}]`,
		"url key":             `[{` + id + `,"media_type":"image/png","byte_size":11,"url":"https://evil.example/x"}]`,
		"missing byte_size":   `[{` + id + `,"media_type":"image/png"}]`,
		"missing media_type":  `[{` + id + `,"byte_size":11}]`,
		"missing id":          `[{"media_type":"image/png","byte_size":11}]`,
		"numeric id":          `[{"id":7,"media_type":"image/png","byte_size":11}]`,
		"string byte_size":    `[{` + id + `,"media_type":"image/png","byte_size":"11"}]`,
		"fractional size":     `[{` + id + `,"media_type":"image/png","byte_size":11.5}]`,
		"negative size":       `[{` + id + `,"media_type":"image/png","byte_size":-11}]`,
		"huge size":           `[{` + id + `,"media_type":"image/png","byte_size":1e300}]`,
		"over the store":      `[{` + id + `,"media_type":"image/png","byte_size":3000001}]`,
		"list media_type":     `[{` + id + `,"media_type":["image/png"],"byte_size":11}]`,
		"svg":                 `[{` + id + `,"media_type":"image/svg+xml","byte_size":11}]`,
		"uppercase id":        `[{"id":"` + strings.ToUpper(good.ID) + `","media_type":"image/png","byte_size":11}]`,
		"good then malformed": `[` + refJSON(good) + `,{"id":"nope","media_type":"image/png","byte_size":11}]`,
	}
	for name, attachments := range malformed {
		client, requests := attachmentServer(t, map[string]string{good.ID: envelope(good.ID, "image/png", len(data), data)})
		command := commandWith(t, `,"attachments":`+attachments)
		if _, err := ParseAttachmentRefs(command.Command); err == nil {
			t.Fatalf("%s: ParseAttachmentRefs accepted %s", name, attachments)
		}
		got, err := client.Attachments(context.Background(), command)
		var refused *AttachmentError
		if !errors.As(err, &refused) || Transient(err) {
			t.Fatalf("%s: got %v, want a non-transient *AttachmentError", name, err)
		}
		if got != nil || requests.Load() != 0 {
			t.Fatalf("%s: %d returned, %d requests; want none of either", name, len(got), requests.Load())
		}
	}
}

func TestParseAttachmentRefsReadsTheLeasedShape(t *testing.T) {
	good := refFor(pngBytes("png"), "image/png")
	refs, err := ParseAttachmentRefs(commandWith(t, `,"attachments":[`+refJSON(good)+`]`).Command)
	if err != nil || len(refs) != 1 || refs[0] != good {
		t.Fatalf("got %+v err=%v want %+v", refs, err, good)
	}
}

var _ io.ReadCloser = (*endlessBody)(nil)
