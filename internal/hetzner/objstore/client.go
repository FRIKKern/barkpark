// Package objstore is the Hetzner Object Storage client — S3-compatible,
// served at https://<location>.your-objectstorage.com (locations fsn1 / nbg1 /
// hel1), spoken here through aws-sdk-go-v2 with SigV4 static credentials. It
// is the foundation for S3 backups and the `bp cloud hetzner …` storage
// surface: put/get/list/delete, presigned GET links, and a manual multipart
// PutLarge for streams and objects past the 5 GB single-PUT ceiling.
//
// Hetzner defaults to VIRTUAL-HOSTED addressing (bucket.<location>.your-
// objectstorage.com), so UsePathStyle stays false. The SigV4 region is the
// location itself — any non-empty value signs, and the location is the
// truthful one.
package objstore

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/service/s3"
	"github.com/aws/aws-sdk-go-v2/service/s3/types"
)

// partSize is the multipart chunk PutLarge uploads per part: 64 MiB — well
// above S3's 5 MiB minimum, and 64 MiB × 10000 parts ≈ 625 GiB headroom.
const partSize = 64 << 20

// Client wraps an s3.Client pointed at one Hetzner Object Storage location.
type Client struct {
	s3       *s3.Client
	presign  *s3.PresignClient
	endpoint string
}

// Option configures NewClient — test seams, like the hetzner.Client options.
type Option func(*options)

type options struct {
	endpoint   string
	httpClient *http.Client
}

// WithEndpoint overrides the derived https://<location>.your-objectstorage.com
// base endpoint (tests point it at a fake).
func WithEndpoint(endpoint string) Option {
	return func(o *options) { o.endpoint = endpoint }
}

// WithHTTPClient overrides the HTTP client the SDK dispatches through (tests
// inject a request-recording transport so no request ever dials).
func WithHTTPClient(c *http.Client) Option {
	return func(o *options) { o.httpClient = c }
}

// Endpoint returns the Hetzner Object Storage base endpoint for a location.
func Endpoint(location string) string {
	return fmt.Sprintf("https://%s.your-objectstorage.com", location)
}

// NewClient builds a Client for one location (fsn1 / nbg1 / hel1) with the
// given S3 access-key pair. No request is made at construction; credentials
// are only exercised on the first call.
func NewClient(location, accessKey, secretKey string, opts ...Option) (*Client, error) {
	if location == "" {
		return nil, fmt.Errorf("objstore: location is required (fsn1, nbg1 or hel1)")
	}
	var o options
	for _, opt := range opts {
		opt(&o)
	}
	endpoint := o.endpoint
	if endpoint == "" {
		endpoint = Endpoint(location)
	}

	loadOpts := []func(*config.LoadOptions) error{
		// SigV4 needs SOME region; the location is the truthful one for Hetzner.
		config.WithRegion(location),
		config.WithCredentialsProvider(credentials.NewStaticCredentialsProvider(accessKey, secretKey, "")),
		// The SDK's 2025 default (checksums "when supported") wraps every PUT in
		// aws-chunked trailer framing that non-AWS S3 backends — Hetzner's
		// included — choke on or store corrupted. "When required" keeps plain
		// SigV4-signed bodies, exactly what Hetzner's own docs prescribe.
		config.WithRequestChecksumCalculation(aws.RequestChecksumCalculationWhenRequired),
		config.WithResponseChecksumValidation(aws.ResponseChecksumValidationWhenRequired),
	}
	if o.httpClient != nil {
		loadOpts = append(loadOpts, config.WithHTTPClient(o.httpClient))
	}
	cfg, err := config.LoadDefaultConfig(context.Background(), loadOpts...)
	if err != nil {
		return nil, fmt.Errorf("objstore: load aws config: %w", err)
	}

	s3c := s3.NewFromConfig(cfg, func(so *s3.Options) {
		so.BaseEndpoint = aws.String(endpoint)
		// Hetzner defaults to virtual-hosted addressing (bucket.<endpoint-host>).
		so.UsePathStyle = false
	})
	return &Client{
		s3:       s3c,
		presign:  s3.NewPresignClient(s3c),
		endpoint: endpoint,
	}, nil
}

// S3 exposes the underlying SDK client for callers that outgrow this wrapper.
func (c *Client) S3() *s3.Client { return c.s3 }

// Bucket is one listed bucket — name and creation time.
type Bucket struct {
	Name    string
	Created time.Time
}

// ListBuckets returns every bucket the credentials own in this location.
func (c *Client) ListBuckets(ctx context.Context) ([]Bucket, error) {
	out, err := c.s3.ListBuckets(ctx, &s3.ListBucketsInput{})
	if err != nil {
		return nil, fmt.Errorf("objstore: list buckets: %w", err)
	}
	buckets := make([]Bucket, 0, len(out.Buckets))
	for _, b := range out.Buckets {
		bucket := Bucket{Name: aws.ToString(b.Name)}
		if b.CreationDate != nil {
			bucket.Created = *b.CreationDate
		}
		buckets = append(buckets, bucket)
	}
	return buckets, nil
}

// CreateBucket creates a bucket in this client's location. This is the S3 API's
// own CreateBucket — it works with existing S3 credentials; only the CREDENTIALS
// (and enabling Object Storage billing) require the Hetzner Console, never the
// bucket itself.
func (c *Client) CreateBucket(ctx context.Context, bucket string) error {
	_, err := c.s3.CreateBucket(ctx, &s3.CreateBucketInput{
		Bucket: aws.String(bucket),
	})
	if err != nil {
		return fmt.Errorf("objstore: create bucket %s: %w", bucket, err)
	}
	return nil
}

// DeleteBucket removes an EMPTY bucket (S3 refuses to delete a non-empty one).
func (c *Client) DeleteBucket(ctx context.Context, bucket string) error {
	_, err := c.s3.DeleteBucket(ctx, &s3.DeleteBucketInput{
		Bucket: aws.String(bucket),
	})
	if err != nil {
		return fmt.Errorf("objstore: delete bucket %s: %w", bucket, err)
	}
	return nil
}

// BaseEndpoint returns the endpoint this client signs against.
func (c *Client) BaseEndpoint() string { return c.endpoint }

// PutObject uploads body as bucket/key in one request. Best with a seekable
// body of known size (a file, bytes.Reader); for unbounded streams or objects
// past 5 GB use PutLarge.
func (c *Client) PutObject(ctx context.Context, bucket, key string, body io.Reader) error {
	_, err := c.s3.PutObject(ctx, &s3.PutObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
		Body:   body,
	})
	if err != nil {
		return fmt.Errorf("objstore: put %s/%s: %w", bucket, key, err)
	}
	return nil
}

// GetObject returns the object's content as a ReadCloser the caller must
// close.
func (c *Client) GetObject(ctx context.Context, bucket, key string) (io.ReadCloser, error) {
	out, err := c.s3.GetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return nil, fmt.Errorf("objstore: get %s/%s: %w", bucket, key, err)
	}
	return out.Body, nil
}

// Object is one listed entry — key, byte size, last modification time.
type Object struct {
	Key          string
	Size         int64
	LastModified time.Time
}

// ListObjects returns every object under prefix (all pages walked; an empty
// prefix lists the whole bucket).
func (c *Client) ListObjects(ctx context.Context, bucket, prefix string) ([]Object, error) {
	var objects []Object
	paginator := s3.NewListObjectsV2Paginator(c.s3, &s3.ListObjectsV2Input{
		Bucket: aws.String(bucket),
		Prefix: aws.String(prefix),
	})
	for paginator.HasMorePages() {
		page, err := paginator.NextPage(ctx)
		if err != nil {
			return nil, fmt.Errorf("objstore: list %s/%s*: %w", bucket, prefix, err)
		}
		for _, obj := range page.Contents {
			o := Object{Key: aws.ToString(obj.Key)}
			if obj.Size != nil {
				o.Size = *obj.Size
			}
			if obj.LastModified != nil {
				o.LastModified = *obj.LastModified
			}
			objects = append(objects, o)
		}
	}
	return objects, nil
}

// DeleteObject removes bucket/key. S3 DELETE is idempotent by contract —
// deleting an absent key succeeds.
func (c *Client) DeleteObject(ctx context.Context, bucket, key string) error {
	_, err := c.s3.DeleteObject(ctx, &s3.DeleteObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return fmt.Errorf("objstore: delete %s/%s: %w", bucket, key, err)
	}
	return nil
}

// PresignGetObject returns a time-limited GET URL for bucket/key — how a
// backup or export gets handed to a browser/customer without sharing the
// account credentials.
func (c *Client) PresignGetObject(ctx context.Context, bucket, key string, expires time.Duration) (string, error) {
	req, err := c.presign.PresignGetObject(ctx, &s3.GetObjectInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	}, s3.WithPresignExpires(expires))
	if err != nil {
		return "", fmt.Errorf("objstore: presign get %s/%s: %w", bucket, key, err)
	}
	return req.URL, nil
}

// PutLarge streams body into bucket/key via the multipart API in 64 MiB parts
// — the path for unbounded streams (pg_dump pipes) and objects past the 5 GB
// single-PUT ceiling. On any part failure the upload is aborted (best-effort,
// fresh bounded context) so no half-finished multipart lingers accruing
// storage.
func (c *Client) PutLarge(ctx context.Context, bucket, key string, body io.Reader) error {
	create, err := c.s3.CreateMultipartUpload(ctx, &s3.CreateMultipartUploadInput{
		Bucket: aws.String(bucket),
		Key:    aws.String(key),
	})
	if err != nil {
		return fmt.Errorf("objstore: create multipart %s/%s: %w", bucket, key, err)
	}
	uploadID := create.UploadId

	abort := func() {
		actx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
		_, _ = c.s3.AbortMultipartUpload(actx, &s3.AbortMultipartUploadInput{
			Bucket:   aws.String(bucket),
			Key:      aws.String(key),
			UploadId: uploadID,
		})
	}

	var completed []types.CompletedPart
	buf := make([]byte, partSize)
	partNum := int32(1)
	for {
		n, rerr := io.ReadFull(body, buf)
		if n > 0 {
			part, uerr := c.s3.UploadPart(ctx, &s3.UploadPartInput{
				Bucket:     aws.String(bucket),
				Key:        aws.String(key),
				UploadId:   uploadID,
				PartNumber: aws.Int32(partNum),
				Body:       newSectionReader(buf[:n]),
			})
			if uerr != nil {
				abort()
				return fmt.Errorf("objstore: upload part %d of %s/%s: %w", partNum, bucket, key, uerr)
			}
			completed = append(completed, types.CompletedPart{
				ETag:       part.ETag,
				PartNumber: aws.Int32(partNum),
			})
			partNum++
		}
		if rerr == io.EOF || rerr == io.ErrUnexpectedEOF {
			break
		}
		if rerr != nil {
			abort()
			return fmt.Errorf("objstore: read body for %s/%s: %w", bucket, key, rerr)
		}
	}

	// A zero-byte body still needs one (empty) part or S3 rejects the complete
	// call with "must specify at least one part".
	if len(completed) == 0 {
		part, uerr := c.s3.UploadPart(ctx, &s3.UploadPartInput{
			Bucket:     aws.String(bucket),
			Key:        aws.String(key),
			UploadId:   uploadID,
			PartNumber: aws.Int32(1),
			Body:       newSectionReader(nil),
		})
		if uerr != nil {
			abort()
			return fmt.Errorf("objstore: upload empty part of %s/%s: %w", bucket, key, uerr)
		}
		completed = append(completed, types.CompletedPart{ETag: part.ETag, PartNumber: aws.Int32(1)})
	}

	_, err = c.s3.CompleteMultipartUpload(ctx, &s3.CompleteMultipartUploadInput{
		Bucket:          aws.String(bucket),
		Key:             aws.String(key),
		UploadId:        uploadID,
		MultipartUpload: &types.CompletedMultipartUpload{Parts: completed},
	})
	if err != nil {
		abort()
		return fmt.Errorf("objstore: complete multipart %s/%s: %w", bucket, key, err)
	}
	return nil
}

// newSectionReader wraps a byte slice as a SEEKABLE reader so the SDK can
// compute the part's content length and payload hash.
func newSectionReader(b []byte) io.ReadSeeker {
	return bytes.NewReader(b)
}
