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
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	// MaxAttachments is the most references (pictures and files together) one
	// send_turn may carry.
	MaxAttachments = 4
	// MaxAttachmentBytes is the chat store's per-attachment ceiling
	// (@max_bytes in api/lib/barkpark/studio_chat/attachments.ex).
	MaxAttachmentBytes = 3_000_000
	// MaxAttachmentResponseBytes caps the body of one attachment read. The
	// largest stored attachment is 4,000,000 base64 characters; the JSON
	// around it (id, media_type, byte_size, key names) is under 200 bytes.
	MaxAttachmentResponseBytes = 4_500_000
	// MaxAttachmentNameBytes is the longest file name
	// (Barkpark.StudioChat.AttachmentName.max_bytes/0).
	MaxAttachmentNameBytes = 255
)

// AttachmentRef is one reference of a leased send_turn: a picture or a file.
// ID is the lowercase sha256 hex of the bytes. Name is set for a file
// (text/plain or application/pdf) and empty for a picture; it is shown to
// the provider and never used in a path.
type AttachmentRef struct {
	ID        string
	MediaType string
	ByteSize  int
	Name      string
}

// Attachment is one fetched picture or file whose bytes were checked against
// its reference. It lives in memory only.
type Attachment struct {
	ID        string
	MediaType string
	Name      string
	Data      []byte
}

// AttachmentError is a reference or a fetched attachment the host refuses.
// The same request would be refused again, so it is not Transient.
type AttachmentError struct{ Reason string }

func (e *AttachmentError) Error() string { return "chat attachment refused: " + e.Reason }

func refuse(format string, args ...any) *AttachmentError {
	return &AttachmentError{Reason: fmt.Sprintf(format, args...)}
}

// ParseAttachmentRefs reads the references of a leased command's payload
// (RemoteCommand.Command["payload"]). No "attachments" key means none.
// Anything other than a list of at most MaxAttachments objects is refused
// whole: a picture has exactly a valid id, media_type and byte_size; a file
// (text/plain or application/pdf) has exactly those and a name that passes
// validAttachmentName.
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
		if !okID || !okType || !okSize {
			return nil, refuse("attachment %d is not a string id, a string media_type and an integer byte_size", i)
		}
		keys, name := 3, ""
		if isFileMediaType(mediaType) {
			rawName, present := fields["name"]
			if !present {
				return nil, refuse("attachment %d is a %s file with no name", i, mediaType)
			}
			if name, ok = rawName.(string); !ok {
				return nil, refuse("attachment %d has a name that is not a string", i)
			}
			keys = 4
		}
		if len(fields) != keys {
			return nil, refuse("attachment %d has %d keys: a picture has exactly id, media_type and byte_size, a file those and name", i, len(fields))
		}
		ref := AttachmentRef{ID: id, MediaType: mediaType, ByteSize: byteSize, Name: name}
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
		return refuse("media type %q is not an accepted picture or file type", r.MediaType)
	}
	if r.ByteSize < 1 || r.ByteSize > MaxAttachmentBytes {
		return refuse("byte_size %d is outside 1..%d", r.ByteSize, MaxAttachmentBytes)
	}
	if isFileMediaType(r.MediaType) {
		if !validAttachmentName(r.Name) {
			return refuse("the file name is empty, over %d bytes, a dot name, or holds a slash, a backslash, or a control or format character", MaxAttachmentNameBytes)
		}
	} else if r.Name != "" {
		return refuse("a picture reference carries no name")
	}
	return nil
}

// validAttachmentName is the server's rule for a file's name
// (Barkpark.StudioChat.AttachmentName.valid?/1). It is refused, never
// cleaned, when it is empty, over 255 bytes, not UTF-8, "." or "..", holds a
// slash or a backslash, or holds a Unicode control (Cc) or format (Cf)
// character, which covers newlines, NUL, DEL, zero-width characters and bidi
// overrides. The name is shown to the provider quoted and is never part of a
// path.
func validAttachmentName(name string) bool {
	if name == "" || len(name) > MaxAttachmentNameBytes || !utf8.ValidString(name) ||
		name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
		return false
	}
	for _, r := range name {
		if unicode.In(r, unicode.Cc, unicode.Cf) {
			return false
		}
	}
	return true
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

// acceptedMediaType is every type the host fetches: the four pictures and the
// two file types.
func acceptedMediaType(mediaType string) bool {
	return isImageMediaType(mediaType) || isFileMediaType(mediaType)
}

func isImageMediaType(mediaType string) bool {
	switch mediaType {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return true
	}
	return false
}

// isFileMediaType is the chat store's file_types/0. Every text is stored as
// text/plain, whatever its name says.
func isFileMediaType(mediaType string) bool {
	return mediaType == "text/plain" || mediaType == "application/pdf"
}

// sniffMediaType names the bytes' type in the chat store's order
// (sniff_media_type/1 in api/lib/barkpark/studio_chat/attachments.ex): the
// four picture prefixes, then %PDF-, then UTF-8 text with no NUL byte.
// Anything else is "".
func sniffMediaType(data []byte) string {
	if image := sniffImageType(data); image != "" {
		return image
	}
	if bytes.HasPrefix(data, []byte("%PDF-")) {
		return "application/pdf"
	}
	if utf8.Valid(data) && bytes.IndexByte(data, 0) < 0 {
		return "text/plain"
	}
	return ""
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

// Attachment fetches one picture or file of the session the lease serves,
// with the Host credential, and returns it only when the bytes are the
// referenced ones: the answer names the same id and media type, the decoded
// length is ByteSize, their sha256 is ID, and they sniff as MediaType the way
// the chat store sniffs them (sniffMediaType). A bad reference
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
	if sniffMediaType(data) != ref.MediaType {
		return Attachment{}, refuse("the bytes are not %s", ref.MediaType)
	}
	return Attachment{ID: ref.ID, MediaType: ref.MediaType, Name: ref.Name, Data: data}, nil
}

// Attachments fetches every picture and file a leased command references, in the
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
