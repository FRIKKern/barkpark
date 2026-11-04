package cloudclient

// media_sha1_backfill.go is the client half of `bp barkparks
// backfill-media-sha1`: POST /v1/operator/barkparks/:id/media-sha1-backfill
// (cloud/lib/barkpark_cloud/registry/media_sha1_backfill.ex). The control
// plane asks the box, with the admin token it holds, to hash the media files
// born before media_files.sha1. The reply names media file ids, workspace
// slugs, dataset names and counts, never a secret.

import (
	"context"
	"encoding/json"
	"fmt"
)

// MediaSha1BackfillRequest is the body. Apply false is a dry run. After is
// the cursor from the previous page. Limit 0 means the box's default.
type MediaSha1BackfillRequest struct {
	Apply bool   `json:"apply"`
	After string `json:"after,omitempty"`
	Limit int    `json:"limit,omitempty"`
}

// MediaSha1BackfillFailure is one file the box could not hash, with why.
type MediaSha1BackfillFailure struct {
	ID        string `json:"id"`
	Workspace string `json:"workspace"`
	Dataset   string `json:"dataset"`
	Reason    string `json:"reason"`
}

// MediaSha1BackfillDataset is one workspace and dataset in a dry run.
type MediaSha1BackfillDataset struct {
	Workspace string `json:"workspace"`
	Dataset   string `json:"dataset"`
	Unhashed  int    `json:"unhashed"`
}

// MediaSha1BackfillReply is the box's answer. A dry run fills Datasets. An
// apply fills Hashed, Failed and NextAfter, which is empty after the last
// page. Unhashed counts every file still without a SHA-1.
type MediaSha1BackfillReply struct {
	Applied   bool                       `json:"applied"`
	Unhashed  int                        `json:"unhashed"`
	Datasets  []MediaSha1BackfillDataset `json:"datasets"`
	Hashed    int                        `json:"hashed"`
	Failed    []MediaSha1BackfillFailure `json:"failed"`
	NextAfter string                     `json:"next_after"`
}

// MediaSha1Backfill is the 200 envelope. Raw is the body verbatim.
type MediaSha1Backfill struct {
	Raw        []byte                 `json:"-"`
	BarkparkID string                 `json:"barkpark_id"`
	Backfill   MediaSha1BackfillReply `json:"backfill"`
}

// BackfillMediaSha1 asks the control plane for a dry run or one applied page
// on one instance. Operator only. A refusal surfaces through cloudError.
func (c *Client) BackfillMediaSha1(ctx context.Context, id string, req MediaSha1BackfillRequest) (MediaSha1Backfill, error) {
	rc := *c
	if rc.HTTP == nil {
		rc.HTTP = newHTTPClient(VerifyTimeout)
	}
	status, raw, err := rc.do(ctx, "POST", "/v1/operator/barkparks/"+esc(id)+"/media-sha1-backfill", true, req)
	if err != nil {
		return MediaSha1Backfill{}, err
	}
	if !ok(status) {
		return MediaSha1Backfill{}, cloudError(status, raw)
	}
	var out MediaSha1Backfill
	if err := json.Unmarshal(raw, &out); err != nil {
		return MediaSha1Backfill{}, fmt.Errorf("decode media sha1 backfill response: %w", err)
	}
	if out.BarkparkID == "" {
		return MediaSha1Backfill{}, fmt.Errorf("media sha1 backfill: the control plane answered HTTP %d without a barkpark id", status)
	}
	out.Raw = raw
	return out, nil
}
