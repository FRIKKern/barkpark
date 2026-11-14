package chathost

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"strconv"
	"time"
)

// ImageFetcher reads one picture or file of the session a lease serves and
// returns it only when its bytes are the referenced ones. *Client is the real
// one.
type ImageFetcher interface {
	Attachment(ctx context.Context, leaseID string, ref AttachmentRef) (Attachment, error)
}

// ClaudeImageTypes are the picture types the host hands claude as image
// blocks.
func ClaudeImageTypes() []string {
	return []string{"image/png", "image/jpeg", "image/gif", "image/webp"}
}

// ClaudeAttachmentTypes is what the host advertises as
// capabilities.providers.claude.attachments: the four picture types, then
// the two file types it writes to the session folder and names in the turn.
// The server leases a send_turn that carries an attachment only to a host
// that lists its type (TurnAttachments.admit/3), and admits the file types
// in this key only from the release that knows them
// (RegisteredHost.safe_attachments?/1).
func ClaudeAttachmentTypes() []string {
	return append(ClaudeImageTypes(), "text/plain", "application/pdf")
}

// fetchTurnAttachments reads every referenced picture and file, in order,
// before the provider starts. The server answers only while the lease is
// live, which ends with the command's first error or terminal event, so this
// runs before anything is emitted. One failure fails the turn: the result is
// never a partial list. The error says which picture or file it was and
// never carries its bytes or a response body.
func (h *LocalHandler) fetchTurnAttachments(ctx context.Context, remote RemoteCommand, refs []AttachmentRef) ([]Attachment, error) {
	if h.Images == nil {
		return nil, fmt.Errorf("this turn carries %d attachment(s) and this host has no way to fetch them, so claude was not started", len(refs))
	}
	images, files := 0, 0
	for _, ref := range refs {
		if isFileMediaType(ref.MediaType) {
			files++
		} else {
			images++
		}
	}
	fetched := make([]Attachment, 0, len(refs))
	image, file := 0, 0
	for _, ref := range refs {
		var which string
		if isFileMediaType(ref.MediaType) {
			file++
			which = fmt.Sprintf("file %d of %d", file, files)
		} else {
			image++
			which = fmt.Sprintf("image %d of %d", image, images)
		}
		attachment, err := h.Images.Attachment(ctx, remote.LeaseID, ref)
		if err != nil {
			return nil, attachmentFetchError(which, err)
		}
		fetched = append(fetched, attachment)
	}
	return fetched, nil
}

func attachmentFetchError(which string, err error) error {
	var refused *AttachmentError
	var status *StatusError
	switch {
	case errors.As(err, &refused):
		// The server answered, and the host refuses what it got.
		return fmt.Errorf("refused %s of this turn, so claude was not started: %w", which, err)
	case errors.As(err, &status):
		// The status line only: the body is the server's, not ours to repeat.
		return fmt.Errorf("could not fetch %s of this turn (chat host API %s), so claude was not started", which, status.Status)
	default:
		// Network, timeout, cancellation, revocation. %w keeps
		// context.Canceled and ErrRevoked readable by the runner.
		return fmt.Errorf("could not fetch %s of this turn, so claude was not started: %w", which, err)
	}
}

// saveTurnFiles writes each fetched file under the session folder of cwd
// (WriteTurnFile) and returns the pictures, in order, and the written files,
// in order. refs and fetched are the same list. Any file that cannot be
// written fails the turn before claude starts. After a file is written, old
// session folders are swept; a sweep that fails is logged and the turn goes
// on.
func (h *LocalHandler) saveTurnFiles(cwd, sessionID string, refs []AttachmentRef, fetched []Attachment) ([]Attachment, []TurnFile, error) {
	files := 0
	for _, ref := range refs {
		if isFileMediaType(ref.MediaType) {
			files++
		}
	}
	images := make([]Attachment, 0, len(refs)-files)
	written := make([]TurnFile, 0, files)
	for i, ref := range refs {
		if !isFileMediaType(ref.MediaType) {
			images = append(images, fetched[i])
			continue
		}
		file, err := WriteTurnFile(h.ApprovedRoots, cwd, sessionID, ref, fetched[i].Data)
		if err != nil {
			return nil, nil, fmt.Errorf("could not save file %d of %d of this turn, so claude was not started: %w", len(written)+1, files, err)
		}
		written = append(written, file)
	}
	if files > 0 {
		if _, err := SweepTurnFiles(h.ApprovedRoots, cwd, sessionID, time.Now()); err != nil {
			h.logf("old chat files were not swept: %v", err)
		}
	}
	return images, written, nil
}

// touchTurnFiles marks the session's file folder as used by this turn, so the
// 7-day sweep keeps the files an earlier turn named while the session is in
// use. It runs for every claude turn, with or without files; a session id
// that is not a UUID has no folder. A failure is logged and the turn goes on.
func (h *LocalHandler) touchTurnFiles(cwd, sessionID string) {
	if !isSessionUUID(sessionID) {
		return
	}
	if err := TouchTurnFiles(h.ApprovedRoots, cwd, sessionID, time.Now()); err != nil {
		h.logf("the chat files of this session were not marked as used: %v", err)
	}
}

// fileLine is the sentence that tells claude where a file is. The name and
// the path are quoted with strconv.Quote, so a quote or any character that is
// not printable cannot end the sentence or start a new line. The name rule
// (validAttachmentName) already refuses control, format and line or
// paragraph separator characters; the path is the host's own.
func fileLine(file TurnFile) string {
	return fmt.Sprintf("Attached file %s (%d bytes, %s) saved at %s",
		strconv.Quote(file.Name), file.ByteSize, file.MediaType, strconv.Quote(file.Path))
}

// claudeUserFrame is the stream-json user frame for one turn. Its content is
// the block list the in-process path sends (build_user_content/2 in
// api/lib/barkpark_web/live/studio/chat_live.ex, charter D25): the text block,
// left out when the text is empty, then one text block per written file
// (fileLine) in reference order, then one base64 image block per picture in
// reference order.
func claudeUserFrame(text string, files []TurnFile, images []Attachment) map[string]any {
	content := make([]any, 0, len(files)+len(images)+1)
	if text != "" {
		content = append(content, map[string]any{"type": "text", "text": text})
	}
	for _, file := range files {
		content = append(content, map[string]any{"type": "text", "text": fileLine(file)})
	}
	for _, image := range images {
		content = append(content, map[string]any{
			"type": "image",
			"source": map[string]any{
				"type":       "base64",
				"media_type": image.MediaType,
				"data":       base64.StdEncoding.EncodeToString(image.Data),
			},
		})
	}
	return map[string]any{
		"type":    "user",
		"message": map[string]any{"role": "user", "content": content},
	}
}
