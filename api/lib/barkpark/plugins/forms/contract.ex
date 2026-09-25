defmodule Barkpark.Plugins.Forms.Contract do
  @moduledoc """
  The document contract for hosted-site form intake (task-71082f5541c13b53,
  N-08): two private document types and the one validator every write of
  either type passes through.

  ## `form_endpoint` — the opt-in, one per site per dataset

  An operator (or the control plane, through the instance admin relay) writes
  one `form_endpoint` document into the dataset a hosted site is bound to. Its
  presence is what makes the public endpoint accept posts for that site there;
  without it every post is a 404. Doc id: `form-endpoint-<site>`
  (`endpoint_doc_id/1`).

      %{
        "site"            => "my-blog",                       # site slug
        "enabled"         => true,
        "allowed_origins" => ["https://my-blog.example.com"], # exact origins
        "fields"          => ["name", "email", "message"]     # the field allowlist
      }

  ## `form_submission` — one document per accepted post

      %{
        "site"         => "my-blog",
        "endpoint_id"  => "form-endpoint-my-blog",
        "received_at"  => "2026-09-25T10:00:00.000000Z",
        "fields"       => %{"name" => "Kari", "message" => "Hei"},
        "state"        => "new" | "seen",
        "spam"         => "clean" | "suspected" | "spam",
        "spam_reasons" => ["links"],
        "source"       => %{"origin" => _, "referer" => _, "user_agent" => _}
      }

  `state` is the inbox lifecycle. It is a content field, not the document's
  draft/published status. `spam` is the disposition: `clean` (no signal),
  `suspected` (machine-flagged at intake, still stored so an operator can
  clear it) or `spam` (an operator's verdict).

  ## Where the contract is enforced

  `validate/2` is registered as a pre-write `:check`
  (`Barkpark.Plugins.Forms.pre_write_transforms/0`), so it runs on BOTH writer
  doors (`Content.Writer.create_document/4` and `upsert_document/4`) before
  any row is written — the public endpoint, `/v1/data/mutate`, Studio and a
  later inbox "mark seen" all meet the same rules. A refusal is
  `{:error, {:schema_validation_failed, details}}`, which
  `Content.Errors` already renders as a 422 `validation_failed`.

  `sanitize_fields/2` is the intake half: it judges a raw posted field map
  against the endpoint's allowlist and the size limits and returns either the
  clean map or the reason it was refused. It never truncates and never drops a
  key — an unknown or oversized payload is refused whole, so nothing partial
  is ever stored.
  """

  @submission_type "form_submission"
  @endpoint_type "form_endpoint"

  @states ~w(new seen)
  @spam_dispositions ~w(clean suspected spam)

  # Field-name shape: a leading letter, then letters, digits, `_`, `-`, `.`.
  # It keeps names usable as HTML `name=` values and as JSON keys, and it
  # excludes the `bp_` intake-control prefix (see `reserved_field?/1`).
  @field_name ~r/^[A-Za-z][A-Za-z0-9_.-]{0,63}$/
  # The site slug shape the box's deploy engine already uses
  # (`Barkpark.Sites.DeployRequest`), so one slug names the site everywhere.
  @site_slug ~r/^[a-z0-9][a-z0-9-]{0,62}$/

  @max_fields 30
  @max_value_bytes 5_000
  @max_list_items 20
  @max_fields_bytes 32_768
  @max_origins 20
  @max_source_value_bytes 512

  @doc "The submission document type."
  def submission_type, do: @submission_type

  @doc "The endpoint (opt-in) document type."
  def endpoint_type, do: @endpoint_type

  @doc "Inbox lifecycle states, in order."
  def states, do: @states

  @doc "Spam dispositions."
  def spam_dispositions, do: @spam_dispositions

  @doc "The intake limits, for callers and tests that must agree with them."
  def limits do
    %{
      max_fields: @max_fields,
      max_value_bytes: @max_value_bytes,
      max_list_items: @max_list_items,
      max_fields_bytes: @max_fields_bytes
    }
  end

  @doc "True when `slug` is a well-formed site slug."
  def site_slug?(slug) when is_binary(slug), do: Regex.match?(@site_slug, slug)
  def site_slug?(_), do: false

  @doc "The deterministic id of a site's `form_endpoint` document."
  def endpoint_doc_id(site) when is_binary(site), do: "form-endpoint-" <> site

  @doc """
  Build a submission's content map. Pure; the result satisfies `validate/2`
  when `fields` came out of `sanitize_fields/2`.
  """
  def new_submission(%{site: site, fields: fields} = attrs) do
    %{
      "site" => site,
      "endpoint_id" => endpoint_doc_id(site),
      "received_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "fields" => fields,
      "state" => "new",
      "spam" => Map.get(attrs, :spam, "clean"),
      "spam_reasons" => Map.get(attrs, :spam_reasons, []),
      "source" => clean_source(Map.get(attrs, :source, %{}))
    }
  end

  defp clean_source(source) do
    for {k, v} <- source, is_binary(v), v != "", into: %{} do
      {to_string(k), truncate_bytes(v, @max_source_value_bytes)}
    end
  end

  # Source metadata is descriptive, not user content, so it is the one place a
  # long value is shortened rather than refused: a long Referer must not make
  # an otherwise valid submission fail.
  defp truncate_bytes(s, max) when byte_size(s) <= max, do: s

  defp truncate_bytes(s, max) do
    s
    |> binary_part(0, max)
    |> String.chunk(:valid)
    |> Enum.filter(&String.valid?/1)
    |> Enum.join()
  end

  # ── intake: the posted field map ──────────────────────────────────────────

  @doc """
  Judge a posted field map against `allowed` (the endpoint's `fields` list).

  Returns `{:ok, fields}` or one of:

    * `{:error, {:unknown_fields, names}}` — a key outside the allowlist;
    * `{:error, {:too_large, detail}}` — too many fields, a value over
      #{@max_value_bytes} bytes, a list over #{@max_list_items} items, or
      more than #{@max_fields_bytes} bytes in total;
    * `{:error, {:invalid, detail}}` — a value that is not a string or a list
      of strings, or a submission with no non-empty value.

  Blank values are omitted from the stored map (an empty optional input is
  normal in an HTML form); nothing else is ever dropped.
  """
  def sanitize_fields(raw, allowed) when is_map(raw) and is_list(allowed) do
    allowed_set = MapSet.new(allowed)
    keys = Map.keys(raw)

    unknown =
      keys
      |> Enum.reject(&(is_binary(&1) and MapSet.member?(allowed_set, &1)))
      |> Enum.map(&to_string/1)

    cond do
      unknown != [] ->
        {:error, {:unknown_fields, Enum.sort(unknown)}}

      map_size(raw) > @max_fields ->
        {:error, {:too_large, "more than #{@max_fields} fields"}}

      true ->
        raw
        |> Enum.reduce_while({:ok, %{}, 0}, fn {k, v}, {:ok, acc, bytes} ->
          case clean_value(v) do
            {:ok, nil} ->
              {:cont, {:ok, acc, bytes}}

            {:ok, clean} ->
              {:cont, {:ok, Map.put(acc, k, clean), bytes + byte_size(k) + value_bytes(clean)}}

            {:error, reason} ->
              {:halt, {:error, reason, k}}
          end
        end)
        |> case do
          {:error, {kind, detail}, k} ->
            {:error, {kind, "#{k}: #{detail}"}}

          {:ok, _acc, bytes} when bytes > @max_fields_bytes ->
            {:error, {:too_large, "more than #{@max_fields_bytes} bytes in total"}}

          {:ok, acc, _} when map_size(acc) == 0 ->
            {:error, {:invalid, "no field has a value"}}

          {:ok, acc, _} ->
            {:ok, acc}
        end
    end
  end

  def sanitize_fields(_raw, _allowed), do: {:error, {:invalid, "fields must be an object"}}

  defp clean_value(v) when is_binary(v) do
    cond do
      not String.valid?(v) -> {:error, {:invalid, "is not valid UTF-8"}}
      byte_size(v) > @max_value_bytes -> {:error, {:too_large, "over #{@max_value_bytes} bytes"}}
      String.trim(v) == "" -> {:ok, nil}
      true -> {:ok, v}
    end
  end

  defp clean_value(list) when is_list(list) do
    cond do
      length(list) > @max_list_items ->
        {:error, {:too_large, "over #{@max_list_items} items"}}

      not Enum.all?(list, &is_binary/1) ->
        {:error, {:invalid, "a list may hold only strings"}}

      true ->
        list
        |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
          case clean_value(item) do
            {:ok, nil} -> {:cont, {:ok, acc}}
            {:ok, s} -> {:cont, {:ok, [s | acc]}}
            err -> {:halt, err}
          end
        end)
        |> case do
          {:ok, []} -> {:ok, nil}
          {:ok, items} -> {:ok, Enum.reverse(items)}
          err -> err
        end
    end
  end

  defp clean_value(_), do: {:error, {:invalid, "must be a string or a list of strings"}}

  defp value_bytes(v) when is_binary(v), do: byte_size(v)
  defp value_bytes(l) when is_list(l), do: Enum.reduce(l, 0, &(byte_size(&1) + &2))

  @doc "True for a posted key the intake reserves for itself (`bp_` prefix)."
  def reserved_field?(key) when is_binary(key), do: String.starts_with?(key, "bp_")
  def reserved_field?(_), do: false

  # ── the pre-write check ───────────────────────────────────────────────────

  @doc """
  The pre-write `:check` (`Barkpark.Content.PreWriteTransforms`). `:ok` for
  every type this plugin does not own.
  """
  def validate(type, attrs) when type in [@submission_type, @endpoint_type] do
    content = Map.get(attrs, "content") || Map.get(attrs, :content)

    errors =
      if is_map(content),
        do: errors_for(type, content),
        else: %{"content" => ["must be an object"]}

    if errors == %{}, do: :ok, else: {:error, {:schema_validation_failed, errors}}
  end

  def validate(_type, _attrs), do: :ok

  defp errors_for(@submission_type, c) do
    %{}
    |> require(c, "site", &site_slug?/1, "must be a site slug")
    |> require(c, "endpoint_id", &(is_binary(&1) and &1 != ""), "is required")
    |> require(c, "received_at", &iso8601?/1, "must be an ISO 8601 timestamp")
    |> require(c, "state", &(&1 in @states), "must be one of #{Enum.join(@states, ", ")}")
    |> require(
      c,
      "spam",
      &(&1 in @spam_dispositions),
      "must be one of #{Enum.join(@spam_dispositions, ", ")}"
    )
    |> require(
      c,
      "fields",
      &stored_fields?/1,
      "must be an object of at most #{@max_fields} string or string-list values within the size limits"
    )
    |> optional(c, "spam_reasons", &string_list?/1, "must be a list of strings")
    |> optional(c, "source", &source?/1, "must be an object of strings")
  end

  defp errors_for(@endpoint_type, c) do
    %{}
    |> require(c, "site", &site_slug?/1, "must be a site slug")
    |> require(c, "enabled", &is_boolean/1, "must be true or false")
    |> require(
      c,
      "allowed_origins",
      &origins?/1,
      "must be a non-empty list of at most #{@max_origins} origins like https://example.com"
    )
    |> require(
      c,
      "fields",
      &field_names?/1,
      "must be a non-empty list of at most #{@max_fields} field names"
    )
  end

  defp require(errors, c, key, pred, msg) do
    case Map.fetch(c, key) do
      {:ok, v} -> if pred.(v), do: errors, else: Map.put(errors, key, [msg])
      :error -> Map.put(errors, key, ["is required"])
    end
  end

  defp optional(errors, c, key, pred, msg) do
    case Map.fetch(c, key) do
      {:ok, nil} -> errors
      {:ok, v} -> if pred.(v), do: errors, else: Map.put(errors, key, [msg])
      :error -> errors
    end
  end

  defp iso8601?(v) when is_binary(v), do: match?({:ok, _, _}, DateTime.from_iso8601(v))
  defp iso8601?(_), do: false

  defp string_list?(v), do: is_list(v) and Enum.all?(v, &is_binary/1)

  defp source?(v) when is_map(v), do: Enum.all?(v, fn {k, s} -> is_binary(k) and is_binary(s) end)
  defp source?(_), do: false

  defp stored_fields?(v) when is_map(v) do
    names = Map.keys(v)

    map_size(v) <= @max_fields and Enum.all?(names, &field_name?/1) and
      match?({:ok, _}, sanitize_fields(v, names)) and map_size(v) > 0
  end

  defp stored_fields?(_), do: false

  defp field_names?(v) when is_list(v) do
    v != [] and length(v) <= @max_fields and Enum.all?(v, &field_name?/1) and
      length(Enum.uniq(v)) == length(v)
  end

  defp field_names?(_), do: false

  @doc "True when `name` is an acceptable form field name."
  def field_name?(name) when is_binary(name),
    do: Regex.match?(@field_name, name) and not reserved_field?(name)

  def field_name?(_), do: false

  defp origins?(v) when is_list(v),
    do: v != [] and length(v) <= @max_origins and Enum.all?(v, &origin?/1)

  defp origins?(_), do: false

  @doc """
  True when `v` is a bare origin — `scheme://host[:port]`, http or https, no
  path, query or fragment — already in the normalised form `normalize_origin/1`
  produces, so the endpoint can compare by string equality.
  """
  def origin?(v) when is_binary(v), do: normalize_origin(v) == {:ok, v}
  def origin?(_), do: false

  @doc "Normalise an `Origin` header value, or `:error` when it is not one."
  def normalize_origin(v) when is_binary(v) do
    case URI.parse(v) do
      %URI{
        scheme: scheme,
        host: host,
        port: port,
        path: path,
        query: nil,
        fragment: nil,
        userinfo: nil
      }
      when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, ""] ->
        scheme = String.downcase(scheme)
        host = String.downcase(host)
        default = if scheme == "https", do: 443, else: 80

        if port in [nil, default],
          do: {:ok, "#{scheme}://#{host}"},
          else: {:ok, "#{scheme}://#{host}:#{port}"}

      _ ->
        :error
    end
  end

  def normalize_origin(_), do: :error
end
