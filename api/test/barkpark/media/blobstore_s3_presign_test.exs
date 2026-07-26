defmodule Barkpark.Media.Blobstore.S3.PresignTest do
  @moduledoc """
  Pins the hand-rolled SigV4 query presigner to the OFFICIAL AWS test vector
  (S3 docs, "Authenticating Requests: Using Query Parameters"). The vector is
  the whole point of hand-rolling without a client dep: a wrong
  canonicalization (encoding alphabet, header block shape, scope order,
  signing-key chain) cannot produce the published signature, so this single
  end-to-end assertion covers the full algorithm.

  `now:` is injected everywhere — signatures are pure functions of their
  inputs here, never of the wall clock.
  """
  use ExUnit.Case, async: true

  alias Barkpark.Media.Blobstore.S3.Presign

  # The AWS-published example (S3 API docs, "Authenticating Requests: Using
  # Query Parameters"): GET https://examplebucket.s3.amazonaws.com/test.txt —
  # virtual-hosted style, so the bucket lives in the ENDPOINT HOST and the
  # config bucket is "" — us-east-1, 20130524T000000Z, 86400s expiry, signed
  # header set = host.
  @aws_config %{
    endpoint: "https://examplebucket.s3.amazonaws.com",
    bucket: "",
    region: "us-east-1",
    access_key_id: "AKIAIOSFODNN7EXAMPLE",
    secret_access_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  }
  @aws_now ~U[2013-05-24 00:00:00Z]

  # Path-style variant of the same credentials — the shape the S3 backend
  # actually emits (R2/MinIO require path-style).
  @path_config %{@aws_config | endpoint: "https://s3.amazonaws.com", bucket: "examplebucket"}

  test "matches the official AWS SigV4 query-presign test vector" do
    url = Presign.url("GET", "test.txt", @aws_config, expires_in: 86_400, now: @aws_now)

    assert url ==
             "https://examplebucket.s3.amazonaws.com/test.txt" <>
               "?X-Amz-Algorithm=AWS4-HMAC-SHA256" <>
               "&X-Amz-Credential=AKIAIOSFODNN7EXAMPLE%2F20130524%2Fus-east-1%2Fs3%2Faws4_request" <>
               "&X-Amz-Date=20130524T000000Z" <>
               "&X-Amz-Expires=86400" <>
               "&X-Amz-SignedHeaders=host" <>
               "&X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"
  end

  test "extra query params participate in the signature and sort canonically" do
    plain = Presign.url("GET", "test.txt", @aws_config, expires_in: 3600, now: @aws_now)

    with_override =
      Presign.url("GET", "test.txt", @aws_config,
        expires_in: 3600,
        now: @aws_now,
        extra_query: [{"response-content-type", "application/octet-stream"}]
      )

    # The override must appear in the URL AND change the signature — an
    # unsigned response-content-type would be silently ignored by the bucket.
    assert with_override =~ "response-content-type=application%2Foctet-stream"

    [plain_sig, override_sig] =
      for url <- [plain, with_override] do
        %{"X-Amz-Signature" => sig} = URI.decode_query(URI.parse(url).query)
        sig
      end

    refute plain_sig == override_sig
  end

  test "path segments are RFC3986-encoded with '/' preserved as separator" do
    url =
      Presign.url("GET", "2026/07/rått bilde.png", @path_config,
        expires_in: 3600,
        now: @aws_now
      )

    assert URI.parse(url).path == "/examplebucket/2026/07/r%C3%A5tt%20bilde.png"
  end

  test "non-default endpoint ports are carried in the signed host (MinIO-style)" do
    config = %{@path_config | endpoint: "http://localhost:9000"}
    url = Presign.url("PUT", "a.txt", config, expires_in: 60, now: @aws_now)

    assert String.starts_with?(url, "http://localhost:9000/examplebucket/a.txt?")
    assert url =~ "X-Amz-Signature="
  end
end
