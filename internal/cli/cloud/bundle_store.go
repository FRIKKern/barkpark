package cloud

// bundle_store.go — the BundleStore seam: the narrow object-store contract the
// bundle library (bundle.go) reads and writes through, plus the real Hetzner
// Object Storage adapter. Tests run against the in-memory NewFakeBundleStore
// (fake.go) so no gate ever dials S3 (charter Decision 14).
//
// The seam is bucket-BOUND: an adapter is built for one bucket and speaks pure
// keys, so the bundle library never threads a bucket name and a future provider
// (an Azure Blob store, a local-disk store) drops in as another implementation.

import (
	"context"
	"io"

	"github.com/FRIKKern/barkpark/internal/hetzner/objstore"
)

// BundleStore is the object-store contract a bundle is written to and read from.
// It is deliberately four methods — the minimum the writer (PutLarge, streaming)
// and reader (Get/List, and Delete for pruning) need. A provider satisfies it by
// binding a bucket; the bundle library stays bucket-agnostic. The signatures are
// PINNED (charter Decision 38) — S14b/c/d/e implement against them.
type BundleStore interface {
	// PutLarge streams r to key via multipart upload — the path for pg_dump
	// pipes and media tarballs past the single-PUT ceiling.
	PutLarge(ctx context.Context, key string, r io.Reader) error
	// Get opens key for reading; the caller closes the reader.
	Get(ctx context.Context, key string) (io.ReadCloser, error)
	// List returns every object key under prefix (all pages walked).
	List(ctx context.Context, prefix string) ([]string, error)
	// Delete removes key (idempotent — an absent key is not an error).
	Delete(ctx context.Context, key string) error
}

// objstoreBundleStore adapts a Hetzner Object Storage *objstore.Client to the
// BundleStore seam, binding one bucket so the bundle library speaks pure keys.
type objstoreBundleStore struct {
	c      *objstore.Client
	bucket string
}

// NewObjstoreBundleStore binds an objstore client + bucket into a BundleStore.
// The client already fronts S3 multipart/list/get/delete; this is a thin,
// bucket-fixing shim.
func NewObjstoreBundleStore(c *objstore.Client, bucket string) BundleStore {
	return &objstoreBundleStore{c: c, bucket: bucket}
}

func (s *objstoreBundleStore) PutLarge(ctx context.Context, key string, r io.Reader) error {
	return s.c.PutLarge(ctx, s.bucket, key, r)
}

func (s *objstoreBundleStore) Get(ctx context.Context, key string) (io.ReadCloser, error) {
	return s.c.GetObject(ctx, s.bucket, key)
}

func (s *objstoreBundleStore) List(ctx context.Context, prefix string) ([]string, error) {
	objs, err := s.c.ListObjects(ctx, s.bucket, prefix)
	if err != nil {
		return nil, err
	}
	out := make([]string, 0, len(objs))
	for _, o := range objs {
		out = append(out, o.Key)
	}
	return out, nil
}

func (s *objstoreBundleStore) Delete(ctx context.Context, key string) error {
	return s.c.DeleteObject(ctx, s.bucket, key)
}

// compile-time assertion that the real adapter satisfies the seam.
var _ BundleStore = (*objstoreBundleStore)(nil)
