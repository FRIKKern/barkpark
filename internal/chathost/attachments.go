package chathost

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"net/http"
)

const (
	// MaxAttachments is the most image references one send_turn may carry.
	MaxAttachments = 4
	// MaxAttachmentBytes is the chat store's per-attachment ceiling
	// (@max_bytes in api/lib/barkpark/studio_chat/attachments.ex).
	MaxAttachmentBytes = 3_000_000
	// MaxAttachmentResponseBytes caps the body of one attachment read. The
	// largest stored image is 4,000,000 base64 characters; the JSON around it
	// (id, media_type, byte_size, key names) is under 200 bytes.
	MaxAttachmentResponseBytes = 4_500_000
)

// AttachmentRef is one image reference of a leased send_turn. ID is the
// lowercase sha256 hex of the image bytes.
type AttachmentRef struct {
	ID        string
	MediaType string
	ByteSize  int
}

// Attachment is one fetched image whose bytes were checked against its
// reference. It lives in memory only.
type Attachment struct {
	ID        string
	MediaType string
	Data      []byte
}

// AttachmentError is a reference or a fetched attachment the host refuses.
// The same request would be refused again, so it is not Transient.
type AttachmentError struct{ Reason string }

func (e *AttachmentError) Error() string { return "chat attachment refused: " + e.Reason }

func refuse(format string, args ...any) *AttachmentError {
	return &AttachmentError{Reason: fmt.Sprintf(format, args...)}
}

// ParseAttachmentRefs reads the image references of a leased command's
// payload (RemoteCommand.Command["payload"]). No "attachments" key means none.
// Anything other than a list of at most MaxAttachments objects, each with
// exactly a valid id, media_type and byte_size, is refused whole.
func ParseAttachmentRefs(payload map[string]any) ([]AttachmentRef, error) {
	raw, present := payload["attachments"]
	if !present {
		return nil, nil
	}
	list, ok := raw.([]any)
	if !ok {
		return nil, refuse("attachments is not a list")
	}
	if len(list) > MaxAttachments {
		return nil, refuse("%d attachments, at most %d are allowed", len(list), MaxAttachments)
	}
	refs := make([]AttachmentRef, 0, len(list))
	for i, entry := range list {
		fields, ok := entry.(map[string]any)
		if !ok {
			return nil, refuse("attachment %d is not an object", i)
		}
		id, okID := fields["id"].(string)
		mediaType, okType := fields["media_type"].(string)
		byteSize, okSize := wholeNumber(fields["byte_size"])
		if len(fields) != 3 || !okID || !okType || !okSize {
			return nil, refuse("attachment %d is not exactly a string id, a string media_type and an integer byte_size", i)
		}
		ref := AttachmentRef{ID: id, MediaType: mediaType, ByteSize: byteSize}
		if refused := ref.validate(); refused != nil {
			return nil, refuse("attachment %d: %s", i, refused.Reason)
		}
		refs = append(refs, ref)
	}
	return refs, nil
}

// wholeNumber accepts the JSON decoder's float64 (or a Go int) when it is a
// whole number no larger than the store's ceiling.
func wholeNumber(value any) (int, bool) {
	switch n := value.(type) {
	case int:
		return n, true
	case float64:
		if n != math.Trunc(n) || n < 0 || n > MaxAttachmentBytes {
			return 0, false
		}
		return int(n), true
	}
	return 0, false
}

func (r AttachmentRef) validate() *AttachmentError {
	if !isAttachmentID(r.ID) {
		return refuse("id is not 64 lowercase hex characters")
	}
	if !acceptedMediaType(r.MediaType) {
		return refuse("media type %q is not an accepted image type", r.MediaType)
	}
	if r.ByteSize < 1 || r.ByteSize > MaxAttachmentBytes {
		return refuse("byte_size %d is outside 1..%d", r.ByteSize, MaxAttachmentBytes)
	}
	return nil
}

func isAttachmentID(id string) bool {
	if len(id) != sha256.Size*2 {
		return false
	}
	for _, c := range []byte(id) {
		if (c < '0' || c > '9') && (c < 'a' || c > 'f') {
			return false
		}
	}
	return true
}

// isLeaseID keeps anything that could change the request path (a slash, a
// dot segment, a query, an escape) out of the URL. Lease ids are UUIDs.
func isLeaseID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, c := range []byte(id) {
		switch {
		case c >= '0' && c <= '9', c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c == '-', c == '_':
		default:
			return false
		}
	}
	return true
}

func acceptedMediaType(mediaType string) bool {
	switch mediaType {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return true
	}
	return false
}

// sniffImageType names the image type by its magic numbers, the same four
// prefixes the chat store sniffs. Anything else is "".
func sniffImageType(data []byte) string {
	switch {
	case bytes.HasPrefix(data, []byte("\x89PNG\r\n\x1a\n")):
		return "image/png"
	case bytes.HasPrefix(data, []byte{0xFF, 0xD8, 0xFF}):
		return "image/jpeg"
	case bytes.HasPrefix(data, []byte("GIF87a")), bytes.HasPrefix(data, []byte("GIF89a")):
		return "image/gif"
	case len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP":
		return "image/webp"
	}
	return ""
}

// Attachment fetches one image of the session the lease serves, with the Host
// credential, and returns it only when the bytes are the referenced ones: the
// answer names the same id and media type, the decoded length is ByteSize,
// their sha256 is ID, and their magic numbers say MediaType. A bad reference
// or lease id is refused before any request. The server answers only while
// the lease is live, which ends with the command's first error or terminal
// event.
func (c *Client) Attachment(ctx context.Context, leaseID string, ref AttachmentRef) (Attachment, error) {
	if !isLeaseID(leaseID) {
		return Attachment{}, refuse("lease id is not a plain identifier")
	}
	if refused := ref.validate(); refused != nil {
		return Attachment{}, refused
	}

	resp, err := c.send(ctx, http.MethodGet, "/v1/chat-host/leases/"+leaseID+"/attachments/"+ref.ID, true, nil)
	if err != nil {
		return Attachment{}, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, MaxAttachmentResponseBytes+1))
	if err != nil {
		return Attachment{}, err
	}
	if len(body) > MaxAttachmentResponseBytes {
		return Attachment{}, refuse("response is over %d bytes", MaxAttachmentResponseBytes)
	}

	var envelope struct {
		Attachment struct {
			ID        string `json:"id"`
			MediaType string `json:"media_type"`
			Data      string `json:"data"`
		} `json:"attachment"`
	}
	if err := json.Unmarshal(body, &envelope); err != nil {
		return Attachment{}, fmt.Errorf("decode chat attachment: %w", err)
	}
	got := envelope.Attachment
	if got.ID != ref.ID {
		return Attachment{}, refuse("response is for another id")
	}
	if got.MediaType != ref.MediaType {
		return Attachment{}, refuse("response media type %q is not the referenced %s", got.MediaType, ref.MediaType)
	}
	data, err := base64.StdEncoding.DecodeString(got.Data)
	if err != nil {
		return Attachment{}, refuse("data is not base64")
	}
	if len(data) != ref.ByteSize {
		return Attachment{}, refuse("%d bytes, the reference says %d", len(data), ref.ByteSize)
	}
	sum := sha256.Sum256(data)
	if subtle.ConstantTimeCompare([]byte(hex.EncodeToString(sum[:])), []byte(ref.ID)) != 1 {
		return Attachment{}, refuse("sha256 of the bytes is not the id")
	}
	if sniffImageType(data) != ref.MediaType {
		return Attachment{}, refuse("the bytes are not %s", ref.MediaType)
	}
	return Attachment{ID: ref.ID, MediaType: ref.MediaType, Data: data}, nil
}

// Attachments fetches every image a leased command references, in the
// command's order. The references are in the command's payload
// (command.Command["payload"]["attachments"]), where the server leases them.
// Any refused reference or failed fetch fails the whole set: the result is
// nil, never a partial list. A bad reference is refused before the first
// request.
func (c *Client) Attachments(ctx context.Context, command RemoteCommand) ([]Attachment, error) {
	payload, _ := command.Command["payload"].(map[string]any)
	refs, err := ParseAttachmentRefs(payload)
	if err != nil {
		return nil, err
	}
	if len(refs) == 0 {
		return nil, nil
	}
	attachments := make([]Attachment, 0, len(refs))
	for _, ref := range refs {
		attachment, err := c.Attachment(ctx, command.LeaseID, ref)
		if err != nil {
			return nil, err
		}
		attachments = append(attachments, attachment)
	}
	return attachments, nil
}
