defmodule Barkpark.Media.Blobstore.S3.Presign do
  @moduledoc """
  AWS Signature Version 4 QUERY presigning for S3-compatible endpoints — pure
  computation, no HTTP, no deps.

  One signing code path serves every verb: GET redirects (`serve_strategy`),
  the write path (PUT), and DELETE all use presigned URLs, so the HTTP client
  never signs anything itself. The payload hash is the literal
  `UNSIGNED-PAYLOAD` sentinel — mandatory for query presigning, and the reason
  a presigned PUT can stream a body without knowing its digest up front.

  Deliberately hand-rolled instead of pulling a client dep: the algorithm is
  fully specified, ~100 lines, and pinned by the OFFICIAL AWS test vector in
  `blobstore_s3_presign_test.exs` — a wrong canonicalization cannot pass that
  test. `now:` is injectable so signatures are deterministic under test.

  Works against any SigV4 endpoint: Cloudflare R2 (`region: "auto"`), AWS S3,
  MinIO, Backblaze B2, Tigris. Path-style addressing (`{endpoint}/{bucket}/{key}`)
  is used throughout — R2 and MinIO require it, AWS still honours it.
  """

  @algorithm "AWS4-HMAC-SHA256"
  @unsigned_payload "UNSIGNED-PAYLOAD"

  @typedoc "Presign inputs. `:extra_query` carries response-header overrides."
  @type config :: %{
          required(:endpoint) => String.t(),
          required(:bucket) => String.t(),
          required(:region) => String.t(),
          required(:access_key_id) => String.t(),
          required(:secret_access_key) => String.t()
        }

  @doc """
  Build a presigned URL for `method` on `key` in the configured bucket.

  Options:
    * `:expires_in` — seconds the URL stays valid (default 3600, S3 max 604800).
    * `:now` — `DateTime` used for the signature timestamp (default utc now);
      injectable for deterministic tests.
    * `:extra_query` — extra query params baked into the signature, e.g.
      `[{"response-content-type", "application/octet-stream"}]` so the bucket
      echoes the serve edge's stored-XSS headers on redirect delivery.
  """
  @spec url(String.t(), String.t(), config(), keyword()) :: String.t()
  def url(method, key, config, opts \\ []) when is_binary(method) and is_binary(key) do
    expires_in = Keyword.get(opts, :expires_in, 3600)
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    extra_query = Keyword.get(opts, :extra_query, [])

    endpoint_uri = URI.parse(config.endpoint)
    host_header = host_header(endpoint_uri)

    amz_date = format_amz_date(now)
    date = binary_part(amz_date, 0, 8)
    scope = "#{date}/#{config.region}/s3/aws4_request"

    canonical_uri = canonical_uri(config.bucket, key)

    query =
      [
        {"X-Amz-Algorithm", @algorithm},
        {"X-Amz-Credential", "#{config.access_key_id}/#{scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", Integer.to_string(expires_in)},
        {"X-Amz-SignedHeaders", "host"}
      ] ++ extra_query

    canonical_query = canonical_query_string(query)

    canonical_request =
      Enum.join(
        [
          method,
          canonical_uri,
          canonical_query,
          "host:#{host_header}\n",
          "host",
          @unsigned_payload
        ],
        "\n"
      )

    string_to_sign =
      Enum.join(
        [@algorithm, amz_date, scope, hex_sha256(canonical_request)],
        "\n"
      )

    signature =
      config.secret_access_key
      |> signing_key(date, config.region)
      |> hmac(string_to_sign)
      |> Base.encode16(case: :lower)

    base = %URI{endpoint_uri | path: canonical_uri}

    "#{URI.to_string(base)}?#{canonical_query}&X-Amz-Signature=#{signature}"
  end

  # ── canonicalization ───────────────────────────────────────────────────────

  # Path-style: /{bucket}/{key}, each path SEGMENT RFC3986-encoded ('/' kept as
  # the separator). Bucket names are DNS-safe so encoding them is a no-op, but
  # keys may carry any byte the blob allowlist permits. An EMPTY bucket means
  # the bucket lives in the endpoint host (virtual-hosted style) and the URI is
  # just /{key} — also the exact shape of the official AWS test vector.
  defp canonical_uri(bucket, key) do
    segments =
      case bucket do
        "" -> String.split(key, "/")
        bucket -> [bucket | String.split(key, "/")]
      end

    "/" <> Enum.map_join(segments, "/", &uri_encode/1)
  end

  # Sorted by ENCODED name (byte order), values encoded with the same strict
  # alphabet — the SigV4 canonical form. Duplicate keys never occur here.
  defp canonical_query_string(params) do
    params
    |> Enum.map(fn {k, v} -> {uri_encode(k), uri_encode(v)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)
  end

  # RFC3986 unreserved set ONLY (A-Za-z0-9 - . _ ~); everything else — including
  # '/' — becomes uppercase %XX. This is stricter than URI.encode/1's default.
  defp uri_encode(string) do
    for <<byte <- string>>, into: "" do
      if unreserved?(byte) do
        <<byte>>
      else
        "%" <> Base.encode16(<<byte>>, case: :upper)
      end
    end
  end

  defp unreserved?(b)
       when b in ?A..?Z or b in ?a..?z or b in ?0..?9 or b in [?-, ?., ?_, ?~],
       do: true

  defp unreserved?(_), do: false

  # The host header carries the port only when it is non-default for the
  # scheme — signing "host:localhost:9000" while the client sends
  # "host: localhost:9000" is what makes MinIO-style local endpoints verify.
  defp host_header(%URI{host: host, port: port, scheme: scheme}) do
    case {scheme, port} do
      {_, nil} -> host
      {"https", 443} -> host
      {"http", 80} -> host
      {_, port} -> "#{host}:#{port}"
    end
  end

  # ── signing ────────────────────────────────────────────────────────────────

  defp signing_key(secret, date, region) do
    ("AWS4" <> secret)
    |> hmac(date)
    |> hmac(region)
    |> hmac("s3")
    |> hmac("aws4_request")
  end

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  defp hex_sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)

  defp format_amz_date(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end
