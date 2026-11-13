package chathost

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
)

// ImageFetcher reads one image of the session a lease serves and returns it
// only when its bytes are the referenced ones. *Client is the real one.
type ImageFetcher interface {
	Attachment(ctx context.Context, leaseID string, ref AttachmentRef) (Attachment, error)
}

// ClaudeImageTypes is what the host advertises as
// capabilities.providers.claude.attachments: the image types it hands claude
// as image blocks. The server leases a send_turn that carries images only to
// a host that lists their type, and admits this key only from the release
// that knows it (RegisteredHost.safe_attachments?/1).
func ClaudeImageTypes() []string {
	return []string{"image/png", "image/jpeg", "image/gif", "image/webp"}
}

// fetchTurnImages reads every referenced image, in order, before the provider
// starts. The server answers only while the lease is live, which ends with
// the command's first error or terminal event, so this runs before anything
// is emitted. One failure fails the turn: the result is never a partial list.
// The error says which class it was and never carries image bytes or a
// response body.
func (h *LocalHandler) fetchTurnImages(ctx context.Context, remote RemoteCommand, refs []AttachmentRef) ([]Attachment, error) {
	if h.Images == nil {
		return nil, fmt.Errorf("this turn carries %d image(s) and this host has no way to fetch them, so claude was not started", len(refs))
	}
	images := make([]Attachment, 0, len(refs))
	for i, ref := range refs {
		image, err := h.Images.Attachment(ctx, remote.LeaseID, ref)
		if err != nil {
			return nil, imageFetchError(i+1, len(refs), err)
		}
		images = append(images, image)
	}
	return images, nil
}

func imageFetchError(position, total int, err error) error {
	which := fmt.Sprintf("image %d of %d", position, total)
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

// claudeUserFrame is the stream-json user frame for one turn. Its content is
// the block list the in-process path sends (build_user_content/2 in
// api/lib/barkpark_web/live/studio/chat_live.ex, charter D25): the text block,
// left out when the text is empty (an image-only turn), then one base64 image
// block per image in reference order.
func claudeUserFrame(text string, images []Attachment) map[string]any {
	content := make([]any, 0, len(images)+1)
	if text != "" {
		content = append(content, map[string]any{"type": "text", "text": text})
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
