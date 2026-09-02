defmodule BarkparkCloud.ArchiveStore do
  @moduledoc """
  Portable-archive conduit (charter S14 / D38–D39) — a dependency-free S3
  client that lists a team's archived-instance bundles straight out of Hetzner
  Object Storage, and (cch-w54-bl) DELETES one when the retention sweep says
  its window has closed.

  ## Why a hand-rolled S3 reader

  The control plane is a Plug + Bandit JSON API; it carries NO `req`, NO
  `ExAws`, and gets no new one (Golden Rule: two credential planes, one
  dependency budget). Reading a bundle manifest is a bounded greenfield
  primitive — exactly the shape of `BarkparkCloud.DomainStatus`'s TLS dial or
  `BarkparkCloud.Verify`'s probe suite — so it rides the OTP batteries already
  in the release: `:crypto` (SigV4 HMAC-SHA256, transitively via `:ssl`),
  `:inets`/`:ssl` (`:httpc` verified-TLS transport), and `:xmerl`
  (ListObjectsV2 XML). No hex dependency is added.

  ## The manifest IS the index (D39)

  There is NO archives table, no `archived` column, no cache. `manifest.json`
  in the bucket is the projection: list `archives/<team_id>/`, GET+parse each
  manifest, shape the envelope. Persistence lives in object storage; this
  module is a pure read.

  ## Team scoping is the security boundary

  Every list is prefixed `archives/<team_id>/`, and `delete_bundle/2` REFUSES
  a `bundle_ref` that does not start with the requesting team's own prefix
  (`{:error, :cross_team_ref}`) — the one call that can destroy data may not
  take the caller's word for where it points. A team can only ever see, or
  erase, its OWN bundles — the prefix is derived from the authenticated
  `conn.assigns.current_team.id`, never from client input, and the ListObjectsV2
  call carries it as the S3 `prefix` param. `list_archives/1` for team A can
  physically never return a key under `archives/<B>/`.

  ## Total over failure (never a lying empty)

  `list_archives/1` NEVER raises. Unconfigured deployment → `{:error,
  :not_configured}`. Store unreachable / non-2xx / malformed XML → a typed
  `{:error, reason}`. The route degrades these to an honest `{ok: false,
  error: …}` (502-style) — NEVER a fabricated empty-success, which would tell
  an operator their archives are gone when the store is merely down.

  ## SigV4 is proven, not decorative

  `sign_v4/1` and `derive_signing_key/4` are exercised by an AWS-documentation
  known-answer test vector (the signing-key chain + the `get-vanilla` suite
  case) in `archive_store_test.exs`, so the HMAC chain is non-vacuous. The
  Authorization-header shape is additionally asserted over the injectable
  transport fake.
  """

  require Logger

  @service "s3"
  @algorithm "AWS4-HMAC-SHA256"
  @aws4_request "aws4_request"
  @default_location "fsn1"

  # SHA-256 of the empty body — the payload hash for every GET this module
  # signs (it never sends a body). S3 requires it in `x-amz-content-sha256`.
  @empty_body_sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # A truncated listing is followed via the continuation token; bound the walk
  # so a pathological bucket can't spin the request process forever.
  @max_list_pages 20

  @type archive :: %{
          fqdn: String.t(),
          slug: String.t(),
          source_provider: String.t(),
          created_at: String.t() | nil,
          bundle_ref: String.t(),
          spec: %{region: String.t() | nil, server_type: String.t() | nil}
        }

  @doc """
  List a team's portable archives, newest-first.

    * `{:ok, [archive]}` — zero or more parsed manifests (an empty list is a
      TRUE empty: the store answered and the team has no bundles)
    * `{:error, :not_configured}` — no S3 credentials / bucket in this
      deployment
    * `{:error, reason}` — the store was unreachable, answered non-2xx, or
      returned XML/JSON this reader couldn't parse

  The `team_id` is the authenticated team's id; it is the ONLY source of the
  key prefix, so cross-team reads are structurally impossible.
  """
  @spec list_archives(String.t()) :: {:ok, [archive()]} | {:error, atom() | tuple()}
  def list_archives(team_id) when is_binary(team_id) and team_id != "" do
    case store_config() do
      {:error, :not_configured} = err ->
        err

      {:ok, cfg} ->
        prefix = "archives/" <> team_id <> "/"

        with {:ok, keys} <- list_keys(cfg, prefix),
             manifests <- fetch_manifests(cfg, manifest_keys(keys)) do
          {:ok, sort_newest_first(manifests)}
        end
    end
  end

  def list_archives(_), do: {:error, :bad_team}

  @doc """
  Delete ONE bundle — every object under its key prefix — and return how many
  objects were removed.

  This is the erasure path the control plane did not have (cch-w54-bl): a
  decommission `Repo.delete`s the barkpark row, and until this existed the
  bundle it left in object storage (a `pg_dump` plus a media tar — a full copy
  of the customer's content) had no route that could remove it. The retention
  sweep (`BarkparkCloud.Workers.ArchiveRetentionWorker`) is its only scheduled
  caller.

    * `{:ok, n}` — `n` objects deleted (0 when the prefix is already empty; a
      re-run of a completed purge is a no-op, not an error)
    * `{:error, :cross_team_ref}` — `bundle_ref` does not live under
      `archives/<team_id>/`. The one verb that destroys data does NOT take the
      caller's word for where it points; a ref outside the team's own prefix is
      refused before a single request is signed.
    * `{:error, :not_configured}` — no S3 credentials / bucket here
    * `{:error, reason}` — the store was unreachable or answered non-2xx. A
      partial delete reports the FAILURE, never `{:ok, n}` — the sweep must not
      record a purge that did not happen.

  `bundle_ref` is the prefix `list_archives/1` already hands back (e.g.
  `"archives/<team>/<slug>/"`), so a listed row is directly erasable.
  """
  @spec delete_bundle(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def delete_bundle(team_id, bundle_ref)
      when is_binary(team_id) and team_id != "" and is_binary(bundle_ref) do
    team_prefix = "archives/" <> team_id <> "/"

    if String.starts_with?(bundle_ref, team_prefix) and bundle_ref != team_prefix do
      case store_config() do
        {:error, :not_configured} = err ->
          err

        {:ok, cfg} ->
          with {:ok, keys} <- list_keys(cfg, bundle_ref) do
            delete_keys(cfg, keys)
          end
      end
    else
      {:error, :cross_team_ref}
    end
  end

  def delete_bundle(_, _), do: {:error, :bad_team}

  # Delete every key, stopping at the FIRST failure. Stopping (rather than
  # collecting) is deliberate: a store that just refused one object will very
  # likely refuse the rest, and a half-swept prefix that reported success would
  # let the sweep believe a bundle is gone while its pg_dump is still there.
  # The next daily tick re-lists and finishes the job.
  defp delete_keys(cfg, keys) do
    Enum.reduce_while(keys, {:ok, 0}, fn key, {:ok, n} ->
      case signed_request(cfg, "DELETE", "/" <> encode_key_path(key), []) do
        # S3 answers a successful DELETE with 204; a key that was already gone
        # answers 204 as well (DELETE is idempotent), and some gateways say 200.
        {:ok, %{status: status}} when status in 200..299 ->
          {:cont, {:ok, n + 1}}

        {:ok, %{status: status}} ->
          {:halt, {:error, {:delete_status, status, key}}}

        {:error, reason} ->
          {:halt, {:error, {:unreachable, reason}}}
      end
    end)
  end

  # ── configuration ──────────────────────────────────────────────────────────

  # Read the S3 credentials + bucket from application config (runtime.exs wires
  # them from HETZNER_S3_ACCESS_KEY / HETZNER_S3_SECRET_KEY /
  # BARKPARK_BUNDLE_BUCKET). Fail CLOSED when any is blank — an unconfigured
  # deployment degrades honestly, it never dials with empty creds.
  defp store_config do
    cfg = Application.get_env(:barkpark_cloud, __MODULE__, [])
    access = present(cfg[:access_key])
    secret = present(cfg[:secret_key])
    bucket = present(cfg[:bucket])
    location = present(cfg[:location]) || @default_location

    if is_nil(access) or is_nil(secret) or is_nil(bucket) do
      {:error, :not_configured}
    else
      {:ok,
       %{
         access_key: access,
         secret_key: secret,
         bucket: bucket,
         location: location,
         host: "#{bucket}.#{location}.your-objectstorage.com"
       }}
    end
  end

  defp present(v) when is_binary(v) do
    case String.trim(v) do
      "" -> nil
      t -> t
    end
  end

  defp present(_), do: nil

  # ── ListObjectsV2 (paginated) ───────────────────────────────────────────────

  defp list_keys(cfg, prefix), do: list_keys(cfg, prefix, nil, [], @max_list_pages)

  defp list_keys(_cfg, _prefix, _token, acc, 0), do: {:ok, acc}

  defp list_keys(cfg, prefix, token, acc, budget) do
    query =
      [{"list-type", "2"}, {"prefix", prefix}] ++
        if(token, do: [{"continuation-token", token}], else: [])

    case signed_get(cfg, "/", query) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case parse_list_result(body) do
          {:ok, keys, next} ->
            merged = acc ++ keys

            if next do
              list_keys(cfg, prefix, next, merged, budget - 1)
            else
              {:ok, merged}
            end

          {:error, _} = err ->
            err
        end

      {:ok, %{status: status}} ->
        {:error, {:list_status, status}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  # Keys whose object is a bundle manifest. A bundle lives at
  # archives/<team>/<slug>/manifest.json, so a manifest is any key ending in
  # "/manifest.json" (or the bare "manifest.json" at the prefix root).
  defp manifest_keys(keys) do
    Enum.filter(keys, fn key ->
      String.ends_with?(key, "/manifest.json") or key == "manifest.json"
    end)
  end

  # ── manifest GET + parse ────────────────────────────────────────────────────

  # Failures are collected across the WHOLE key list and logged as one summary
  # (see `log_manifest_failures/2`) instead of one Logger.warning per key — a
  # store outage during a listing walk can touch dozens of keys, and per-key
  # logging would flood the log with near-identical lines for a single event.
  defp fetch_manifests(cfg, keys) do
    total = length(keys)

    {manifests, failures} =
      keys
      |> Enum.map(&fetch_manifest(cfg, &1))
      |> Enum.reduce({[], []}, fn
        {:ok, manifest}, {oks, errs} -> {[manifest | oks], errs}
        {:error, reason}, {oks, errs} -> {oks, [reason | errs]}
      end)

    log_manifest_failures(Enum.reverse(failures), total)

    Enum.reverse(manifests)
  end

  # ONE Logger.warning per listing call, however many keys failed: "N/M
  # manifests failed to fetch/parse: <first reason>". The first failure is
  # kept as a representative sample; the rest are counted, not repeated.
  defp log_manifest_failures([], _total), do: :ok

  defp log_manifest_failures(failures, total) do
    failed = length(failures)
    first_reason = hd(failures)

    Logger.warning(
      "archive_store: #{failed}/#{total} manifests failed to fetch/parse: #{first_reason}"
    )
  end

  # A single manifest that fails to fetch or parse is DROPPED, never fatal to
  # the whole listing — one corrupt bundle can't hide the rest. The caller
  # aggregates failures into one summary warning per listing call.
  defp fetch_manifest(cfg, key) do
    case signed_get(cfg, "/" <> encode_key_path(key), []) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        parse_manifest(key, body)

      other ->
        {:error, "manifest fetch failed for #{inspect(key)}: #{inspect(other)}"}
    end
  end

  defp parse_manifest(key, body) do
    case Jason.decode(body) do
      {:ok, %{} = m} ->
        spec = if is_map(m["spec"]), do: m["spec"], else: %{}

        {:ok,
         %{
           fqdn: string_or(m["fqdn"], ""),
           slug: string_or(m["slug"], slug_from_key(key)),
           source_provider: string_or(m["source_provider"], ""),
           created_at: string_or(m["created_at"], nil),
           bundle_ref: string_or(m["bundle_ref"], bundle_prefix(key)),
           spec: %{
             region: string_or(spec["region"], nil),
             server_type: string_or(spec["server_type"], nil)
           }
         }}

      _ ->
        {:error, "manifest #{inspect(key)} is not valid JSON"}
    end
  end

  # The bundle's key PREFIX — the manifest key with its trailing
  # "manifest.json" removed. This is the ref the resurrect surfaces consume
  # (`bp cloud instance resurrect … --bundle <prefix>` / POST /v1/resurrect
  # bundle_ref), so a console row's bundle_ref is directly actionable.
  defp bundle_prefix(key), do: String.trim_trailing(key, "manifest.json")

  # archives/<team>/<slug>/manifest.json → <slug>.
  defp slug_from_key(key) do
    key
    |> String.split("/")
    |> Enum.reverse()
    |> case do
      ["manifest.json", slug | _] -> slug
      _ -> ""
    end
  end

  defp sort_newest_first(manifests) do
    Enum.sort_by(manifests, fn m -> {m.created_at || "", m.slug} end, :desc)
  end

  defp string_or(v, _default) when is_binary(v), do: v
  defp string_or(_v, default), do: default

  # ── SigV4 signed GET dispatch ───────────────────────────────────────────────

  defp signed_get(cfg, path, query), do: signed_request(cfg, "GET", path, query)

  # Build a SigV4-signed request and dispatch it through the injectable
  # transport. `path` is a raw (already-encoded) path; `query` is a list of
  # {k,v} the signer canonicalises identically to the URL it sends. Every verb
  # this module signs is bodiless, so the payload hash is always the
  # empty-body SHA-256 — a DELETE signs exactly like a GET but for the method
  # in the canonical request.
  defp signed_request(cfg, method, path, query) do
    amz_datetime = amz_datetime(DateTime.utc_now())

    signed =
      sign_v4(%{
        method: method,
        host: cfg.host,
        path: path,
        query: query,
        headers: [
          {"host", cfg.host},
          {"x-amz-content-sha256", @empty_body_sha256},
          {"x-amz-date", amz_datetime}
        ],
        payload_hash: @empty_body_sha256,
        amz_datetime: amz_datetime,
        region: cfg.location,
        service: @service,
        access_key: cfg.access_key,
        secret_key: cfg.secret_key
      })

    url = "https://" <> cfg.host <> path <> query_suffix(query)

    headers = [
      {"Authorization", signed.authorization},
      {"x-amz-content-sha256", @empty_body_sha256},
      {"x-amz-date", amz_datetime}
    ]

    dispatch(%{
      method: method |> String.downcase() |> String.to_existing_atom(),
      url: url,
      headers: headers,
      body: ""
    })
  end

  defp query_suffix([]), do: ""
  defp query_suffix(query), do: "?" <> canonical_query(query)

  # ── SigV4 signing (proven by KAT in archive_store_test.exs) ─────────────────

  @doc """
  Produce the SigV4 signing artefacts for one request. Returns
  `%{canonical_request, string_to_sign, signature, signed_headers,
  authorization}`. Exposed (not private) so the known-answer test can assert
  every stage against AWS's published `get-vanilla` vector — the guarantee that
  the chain is non-vacuous.
  """
  @spec sign_v4(map()) :: %{
          canonical_request: String.t(),
          string_to_sign: String.t(),
          signature: String.t(),
          signed_headers: String.t(),
          authorization: String.t()
        }
  def sign_v4(req) do
    date_stamp = String.slice(req.amz_datetime, 0, 8)
    scope = Enum.join([date_stamp, req.region, req.service, @aws4_request], "/")

    {canon_headers, signed_headers} = canonical_headers(req.headers)

    canonical_request =
      Enum.join(
        [
          String.upcase(req.method),
          req.path,
          canonical_query(req.query),
          canon_headers,
          signed_headers,
          req.payload_hash
        ],
        "\n"
      )

    string_to_sign =
      Enum.join(
        [
          @algorithm,
          req.amz_datetime,
          scope,
          hex(sha256(canonical_request))
        ],
        "\n"
      )

    signing_key = derive_signing_key(req.secret_key, date_stamp, req.region, req.service)
    signature = hex(hmac(signing_key, string_to_sign))

    authorization =
      @algorithm <>
        " Credential=" <>
        req.access_key <>
        "/" <>
        scope <>
        ", SignedHeaders=" <>
        signed_headers <>
        ", Signature=" <> signature

    %{
      canonical_request: canonical_request,
      string_to_sign: string_to_sign,
      signature: signature,
      signed_headers: signed_headers,
      authorization: authorization
    }
  end

  @doc """
  Derive the SigV4 signing key: HMAC-chain "AWS4"+secret → date → region →
  service → "aws4_request". Returns the RAW 32-byte key (the KAT hexes it).
  """
  @spec derive_signing_key(String.t(), String.t(), String.t(), String.t()) :: binary()
  def derive_signing_key(secret, date_stamp, region, service) do
    ("AWS4" <> secret)
    |> hmac(date_stamp)
    |> hmac(region)
    |> hmac(service)
    |> hmac(@aws4_request)
  end

  defp canonical_headers(headers) do
    normalized =
      headers
      |> Enum.map(fn {k, v} -> {String.downcase(to_string(k)), String.trim(to_string(v))} end)
      |> Enum.sort_by(fn {k, _} -> k end)

    canon = Enum.map_join(normalized, "", fn {k, v} -> k <> ":" <> v <> "\n" end)
    signed = Enum.map_join(normalized, ";", fn {k, _} -> k end)
    {canon, signed}
  end

  # Canonical query string: each key+value URI-encoded (encode "/" too), sorted
  # by encoded key then value, joined k=v with "&". Empty → "".
  defp canonical_query([]), do: ""

  defp canonical_query(query) do
    query
    |> Enum.map(fn {k, v} -> {uri_encode(to_string(k), true), uri_encode(to_string(v), true)} end)
    |> Enum.sort()
    |> Enum.map_join("&", fn {k, v} -> k <> "=" <> v end)
  end

  # An object key rendered as a canonical URI path: encode each byte per RFC
  # 3986 but PRESERVE the "/" segment separators.
  defp encode_key_path(key), do: uri_encode(key, false)

  # AWS URI-encode: unreserved chars pass; "/" passes iff encode_slash is false;
  # every other byte becomes %XX (uppercase). Operates on raw bytes so UTF-8 is
  # percent-encoded correctly.
  defp uri_encode(str, encode_slash) do
    str
    |> :binary.bin_to_list()
    |> Enum.map_join("", fn byte -> encode_byte(byte, encode_slash) end)
  end

  defp encode_byte(b, _) when b in ?A..?Z or b in ?a..?z or b in ?0..?9, do: <<b>>
  defp encode_byte(b, _) when b in [?-, ?_, ?., ?~], do: <<b>>
  defp encode_byte(?/, false), do: "/"

  defp encode_byte(b, _) do
    "%" <> (b |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(2, "0"))
  end

  # ── ListObjectsV2 XML parse (:xmerl) ────────────────────────────────────────

  # Parse a ListBucketResult: pull every <Contents><Key> and the truncation
  # continuation token. :xmerl_scan works on a charlist; `quiet` suppresses its
  # stderr chatter. A body that isn't parseable XML is a typed error, not a
  # raise.
  defp parse_list_result(body) do
    charlist = :erlang.binary_to_list(body)

    try do
      {doc, _rest} = :xmerl_scan.string(charlist, quiet: true)
      keys = for key <- xpath_texts(doc, ~c"/ListBucketResult/Contents/Key"), do: key
      truncated? = xpath_text(doc, ~c"/ListBucketResult/IsTruncated") == "true"
      token = xpath_text(doc, ~c"/ListBucketResult/NextContinuationToken")
      next = if truncated? and token not in [nil, ""], do: token, else: nil
      {:ok, keys, next}
    catch
      kind, reason ->
        Logger.warning(
          "archive_store: ListObjectsV2 XML parse failed: #{inspect({kind, reason})}"
        )

        {:error, :bad_list_xml}
    end
  end

  defp xpath_texts(doc, path) do
    path
    |> :xmerl_xpath.string(doc)
    |> Enum.map(&node_text/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp xpath_text(doc, path) do
    case :xmerl_xpath.string(path, doc) do
      [node | _] -> node_text(node)
      _ -> nil
    end
  end

  # Concatenate the text children of an :xmlElement (xmerl records; we reach
  # into the tuple positionally to avoid pulling in the xmerl record header).
  defp node_text(element) when is_tuple(element) and elem(element, 0) == :xmlElement do
    element
    |> elem(8)
    |> Enum.map(&node_text/1)
    |> Enum.join("")
    |> String.trim()
  end

  defp node_text(text) when is_tuple(text) and elem(text, 0) == :xmlText do
    # xmlText record: {:xmlText, parents, pos, language, value, type} — the text
    # is the `value` field (position 4), a charlist.
    text |> elem(4) |> to_string()
  end

  defp node_text(_), do: ""

  # ── crypto + hex helpers ────────────────────────────────────────────────────

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256(data), do: :crypto.hash(:sha256, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)

  defp amz_datetime(%DateTime{} = dt) do
    dt
    |> DateTime.truncate(:second)
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end

  # ── transport seam ──────────────────────────────────────────────────────────

  # The injectable transport. Default is the verified-TLS `:httpc` client
  # below; tests wire a fake module (with `request/1`) or a 1-arity fun that
  # records the signed request and returns canned responses.
  defp dispatch(req) do
    case http_client() do
      fun when is_function(fun, 1) -> fun.(req)
      mod -> mod.request(req)
    end
  end

  defp http_client do
    Application.get_env(:barkpark_cloud, :archive_store_http_client, __MODULE__.HttpClient)
  end
end

defmodule BarkparkCloud.ArchiveStore.HttpClient do
  @moduledoc """
  ArchiveStore's HTTP transport — verified-TLS `:httpc`, the same idiom as
  `BarkparkCloud.Verify.HttpClient`. Bodiless verbs only (GET for the reads,
  DELETE for the retention purge) — both ride `:httpc`'s two-tuple request
  form, so neither ever sends a body the signature did not cover. Redirects are NOT auto-followed
  (S3 doesn't redirect a signed request; following one would drop the
  Authorization header). `request/1` takes `%{method, url, headers, body}` and
  returns `{:ok, %{status, body, headers}}` on a completed exchange (any
  status) or `{:error, {:http_client, reason}}` on a transport failure.
  """

  @timeout 10_000
  @connect_timeout 5_000

  @spec request(map()) ::
          {:ok, %{status: non_neg_integer(), body: binary(), headers: [{String.t(), String.t()}]}}
          | {:error, term()}
  def request(%{method: method, url: url, headers: headers}) do
    request_arg = {to_charlist(url), header_charlists(headers)}

    case :httpc.request(method, request_arg, http_opts(), body_format: :binary) do
      {:ok, {{_v, status, _reason}, resp_headers, resp_body}} ->
        {:ok,
         %{status: status, body: to_string(resp_body), headers: normalize_headers(resp_headers)}}

      {:error, reason} ->
        {:error, {:http_client, reason}}
    end
  end

  defp header_charlists(headers) do
    Enum.map(headers, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
  end

  defp normalize_headers(resp_headers) do
    Enum.map(resp_headers, fn {k, v} -> {String.downcase(to_string(k)), to_string(v)} end)
  end

  defp http_opts do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      autoredirect: false,
      timeout: @timeout,
      connect_timeout: @connect_timeout
    ]
  end
end
