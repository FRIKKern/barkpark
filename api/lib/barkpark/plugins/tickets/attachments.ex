defmodule Barkpark.Plugins.Tickets.Attachments do
  @moduledoc """
  The outsider-media trust boundary for ticket attachments.

  Ticket keys are handed to outside users, so `POST /v1/tickets/:id/attachments`
  is exactly the hostile-upload surface. This module is a MANDATORY, plugin-local
  gate — independent of the global (config-gated-off) media allowlist and
  independent of the held upload-hardening draft. When that draft lands, the
  ticket tier becomes its strictest consumer; the vocabulary here (`allowlist`,
  server-derived MIME) is deliberately aligned so it can subsume this gate.

  ## Validation core (pure — this is what the gate tests)

    * `sniff/1` derives the MIME from MAGIC BYTES only. The client `Content-Type`
      and the filename extension are NEVER trusted for authorization — a spoofed
      `.png` that is really an executable is rejected.
    * `allow?/1` checks a MIME against the charter allowlist
      (png/jpeg/gif/webp/pdf/txt/log/zip). Logs and plain text both sniff to
      `text/plain` via a printable-text heuristic (ASCII ratio, or valid
      printable UTF-8 for non-English text) — magic bytes cannot tell a `.log`
      from a `.txt`, and we refuse to trust the extension.
    * `validate/2` composes the size cap (10 MB/file) with the sniff+allow gate
      and returns a TYPED error for every rejection:
      `{:error, :too_large | :mime_spoofed | :mime_not_allowed}`.
    * `validate_count/1` enforces the 10-attachments/ticket cap
      (`{:error, :too_many_attachments}`).

  ## Storage glue (impure)

    * `store/2` persists an already-validated blob through the Media plugin's
      storage internals (`Barkpark.Media.upload/3`) — reusing hashing, disk
      layout and the `mediaAsset` companion doc — then stamps that doc with the
      owning `bp_ticket_id` + `bp_ticket_key_id` so retrieval can be scoped.
    * `count_for_ticket/3` counts a ticket's already-stored attachments.
    * `linked_asset/4` resolves an asset id back to its blob ONLY when it belongs
      to the presented ticket (the retrieval scoping check; foreign = not_found).
  """

  import Ecto.Query

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @typedoc "Every rejection this gate can return — each maps to an honest envelope."
  @type rejection ::
          :too_large | :mime_spoofed | :mime_not_allowed | :too_many_attachments

  # Server-derived MIME allowlist. `text/plain` covers BOTH .txt and .log (a log
  # is printable text; magic bytes can't distinguish the two and the extension is
  # not trusted). Keep this list aligned with the upload-hardening draft.
  @allowlist ~w(
    image/png
    image/jpeg
    image/gif
    image/webp
    application/pdf
    text/plain
    application/zip
  )

  # 10 MB per file, 10 attachments per ticket (charter Decision 4).
  @max_bytes 10 * 1024 * 1024
  @max_attachments 10

  # Printable-text heuristic knobs.
  @text_sample_bytes 1024
  @text_printable_ratio 0.90

  @asset_type "mediaAsset"

  @doc "The server-derived MIME allowlist for the ticket attachment tier."
  @spec allowlist() :: [String.t()]
  def allowlist, do: @allowlist

  @doc "Per-file size cap in bytes (10 MB)."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "Per-ticket attachment count cap."
  @spec max_attachments() :: pos_integer()
  def max_attachments, do: @max_attachments

  # ───────────────────────────── pure validation ────────────────────────────

  @doc """
  Derive a MIME type from the leading magic bytes of `binary`.

  Returns a known MIME string, or `nil` when the bytes match no supported
  signature (and are not printable text). The client Content-Type / filename are
  NEVER consulted — this is the server-derived truth the gate authorizes on.
  """
  @spec sniff(binary()) :: String.t() | nil
  def sniff(<<0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  def sniff(<<"GIF87a", _::binary>>), do: "image/gif"
  def sniff(<<"GIF89a", _::binary>>), do: "image/gif"
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  def sniff(<<"%PDF-", _::binary>>), do: "application/pdf"
  def sniff(<<0x50, 0x4B, 0x03, 0x04, _::binary>>), do: "application/zip"
  # Empty ZIP archive marker (rare, but a valid empty .zip).
  def sniff(<<0x50, 0x4B, 0x05, 0x06, _::binary>>), do: "application/zip"

  def sniff(binary) when is_binary(binary) do
    if printable_text?(binary), do: "text/plain", else: nil
  end

  def sniff(_), do: nil

  @doc "True when `mime` is on the ticket-tier allowlist."
  @spec allow?(String.t() | nil) :: boolean()
  def allow?(mime) when is_binary(mime), do: mime in @allowlist
  def allow?(_), do: false

  @doc """
  Validate one attachment blob.

  Enforces the size cap, then sniffs the MIME from magic bytes and checks the
  allowlist. `opts` may carry `:filename` and `:content_type` — these are used
  ONLY to distinguish a lie (`:mime_spoofed`) from an honestly-disallowed type
  (`:mime_not_allowed`); neither is ever trusted to authorize an upload.

      iex> validate(<<0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10>>)
      {:ok, "image/png"}
  """
  @spec validate(binary(), keyword()) ::
          {:ok, String.t()} | {:error, :too_large | :mime_spoofed | :mime_not_allowed}
  def validate(binary, opts \\ []) when is_binary(binary) do
    cond do
      byte_size(binary) > @max_bytes ->
        {:error, :too_large}

      true ->
        derived = sniff(binary)

        cond do
          allow?(derived) -> {:ok, derived}
          spoofed?(derived, opts) -> {:error, :mime_spoofed}
          true -> {:error, :mime_not_allowed}
        end
    end
  end

  @doc """
  Enforce the per-ticket attachment count cap given the CURRENT count.

  Returns `:ok` while there is room, `{:error, :too_many_attachments}` once the
  ticket is already at the cap (so the Nth+1 upload is refused).
  """
  @spec validate_count(non_neg_integer()) :: :ok | {:error, :too_many_attachments}
  def validate_count(current) when is_integer(current) and current >= 0 do
    if current >= @max_attachments, do: {:error, :too_many_attachments}, else: :ok
  end

  # A blob is "spoofed" when its declared type (Content-Type, else filename
  # extension) claims an ALLOWED type but the server-derived bytes disagree —
  # the classic "executable renamed to .png with Content-Type: image/png". An
  # honestly-declared disallowed type (a real .gz called application/gzip) is
  # NOT spoofed; it is simply `:mime_not_allowed`.
  defp spoofed?(derived, opts) do
    case claimed_type(opts) do
      claimed when is_binary(claimed) -> allow?(claimed) and claimed != derived
      _ -> false
    end
  end

  defp claimed_type(opts) do
    case normalize_mime(Keyword.get(opts, :content_type)) do
      mime when is_binary(mime) and mime != "" ->
        mime

      _ ->
        case Keyword.get(opts, :filename) do
          name when is_binary(name) and name != "" -> MIME.from_path(name)
          _ -> nil
        end
    end
  end

  # Strip params ("image/png; charset=...") and downcase.
  defp normalize_mime(nil), do: nil

  defp normalize_mime(ct) when is_binary(ct) do
    ct |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase()
  end

  defp normalize_mime(_), do: nil

  # Printable-text heuristic over the leading bytes. A NUL byte is a hard binary
  # tell (rejects ELF / Mach-O / PE / UTF-16 immediately). Then: mostly-printable
  # ASCII passes the ratio gate, and anything else must be VALID, printable
  # UTF-8 — so a Norwegian log ("Blåbærsyltetøy") is text/plain while binary
  # junk (whose bytes are almost never a valid UTF-8 sequence) is not.
  defp printable_text?(binary) when byte_size(binary) > 0 do
    sample = binary_part(binary, 0, min(byte_size(binary), @text_sample_bytes))
    bytes = :binary.bin_to_list(sample)

    cond do
      Enum.any?(bytes, &(&1 == 0)) ->
        false

      Enum.count(bytes, &printable_byte?/1) / length(bytes) >= @text_printable_ratio ->
        true

      true ->
        utf8_text?(sample)
    end
  end

  defp printable_text?(_), do: false

  defp printable_byte?(b), do: b in 0x20..0x7E or b in [0x09, 0x0A, 0x0D]

  # The sample may cut a multibyte character at the boundary, so try trimming up
  # to 3 trailing continuation bytes before judging validity. `String.printable?`
  # accepts \n \r \t \e etc., so ANSI-colored logs still count as text.
  defp utf8_text?(sample) do
    Enum.any?(0..3, fn drop ->
      size = byte_size(sample) - drop
      size > 0 and printable_utf8?(binary_part(sample, 0, size))
    end)
  end

  defp printable_utf8?(chunk), do: String.valid?(chunk) and String.printable?(chunk)

  # ─────────────────────────────── storage glue ─────────────────────────────

  @doc """
  Persist a validated blob through the Media plugin's storage internals.

  `opts` (required): `:mime` (server-derived), `:ticket_id`, `:key_id`,
  `:dataset`; optional `:filename` and `:scope` (tenancy keyword opts). The blob
  is written via `Barkpark.Media.upload/3` — reusing the whole media pipeline —
  with the SERVER-DERIVED MIME as the stored content type, then the companion
  `mediaAsset` doc is stamped with `bp_ticket_id` + `bp_ticket_key_id` so
  `linked_asset/4` can scope retrieval to the owning ticket.

  Returns `{:ok, asset_ref}` (a small map safe to embed in a ticket message) or
  `{:error, :storage_unavailable}`.
  """
  @spec store(binary(), keyword()) :: {:ok, map()} | {:error, :storage_unavailable}
  def store(binary, opts) when is_binary(binary) and is_list(opts) do
    mime = Keyword.fetch!(opts, :mime)
    ticket_id = Keyword.fetch!(opts, :ticket_id)
    key_id = Keyword.fetch!(opts, :key_id)
    dataset = Keyword.get(opts, :dataset, "production")
    scope = Keyword.get(opts, :scope, [])
    filename = Keyword.get(opts, :filename) || default_filename(mime)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "bptk-attach-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
      )

    try do
      with :ok <- File.write(tmp, binary),
           upload = %Plug.Upload{path: tmp, filename: filename, content_type: mime},
           {:ok, file} <- Media.upload(upload, dataset, scope) do
        case stamp_asset(file, dataset, ticket_id, key_id) do
          {:ok, _doc} ->
            {:ok,
             %{
               asset_id: file.id,
               filename: filename,
               content_type: mime,
               size: file.size,
               url: "/v1/tickets/#{ticket_id}/attachments/#{file.id}"
             }}

          _ ->
            # The blob landed but the ticket stamp did not — without it the
            # asset is unretrievable (`linked_asset/4` scopes on the stamp) and
            # invisible to the count cap. A 201 pointing at a permanent 404
            # would be a lie, so best-effort delete the orphan and report the
            # store as failed (client retries cleanly).
            _ = Media.delete_file(file.id, scope)
            {:error, :storage_unavailable}
        end
      else
        # Any storage failure (disk fault, or a losing insert race) is reported
        # as transient-unavailable rather than leaking a changeset/500.
        _ -> {:error, :storage_unavailable}
      end
    after
      _ = File.rm(tmp)
    end
  end

  @doc """
  Count the attachments already stored against `ticket_id`.

  Counts `mediaAsset` docs stamped with this `bp_ticket_id` in `dataset`, so the
  count is authoritative even before a message references the blob.
  """
  @spec count_for_ticket(String.t(), String.t(), keyword()) :: non_neg_integer()
  def count_for_ticket(ticket_id, dataset, scope \\ [])
      when is_binary(ticket_id) and is_binary(dataset) do
    Document
    |> where([d], d.type == ^@asset_type and d.dataset == ^dataset)
    |> where([d], fragment("?->>? = ?", d.content, "bp_ticket_id", ^ticket_id))
    |> scope_workspace(scope)
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Resolve `asset_id` to its blob ONLY when it belongs to `ticket_id`.

  This is the retrieval scoping check: an asset that is not stamped to the
  presented ticket (foreign, or non-existent) returns `{:error, :not_found}` so
  the API never leaks that the blob exists.
  """
  @spec linked_asset(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, struct()} | {:error, :not_found}
  def linked_asset(asset_id, ticket_id, dataset, scope \\ [])
      when is_binary(asset_id) and is_binary(ticket_id) and is_binary(dataset) do
    with {:ok, file} <- Media.get_file(asset_id, scope),
         doc when not is_nil(doc) <- Media.asset_doc_for_file(file, file.dataset, scope),
         true <- Map.get(doc.content || %{}, "bp_ticket_id") == ticket_id do
      {:ok, file}
    else
      _ -> {:error, :not_found}
    end
  end

  # Stamp the companion mediaAsset doc with the owning ticket + key. Idempotent
  # (`ensure_for_upload` then upsert) and mirrors `Media.patch_asset_metadata`.
  defp stamp_asset(file, dataset, ticket_id, key_id) do
    with {:ok, doc} <- Assets.ensure_for_upload(file) do
      content =
        (doc.content || %{})
        |> Map.put("bp_ticket_id", ticket_id)
        |> Map.put("bp_ticket_key_id", key_id)

      attrs = %{
        "doc_id" => doc.doc_id,
        "title" => doc.title,
        "status" => doc.status,
        "content" => content
      }

      Content.upsert_document(
        @asset_type,
        attrs,
        dataset,
        [source: :api] ++ Assets.file_scope_opts(file)
      )
    end
  end

  # Same tenancy direction as `Thread.operator_scope/1`: an absent or
  # explicitly-nil `:workspace_id` is the SHARED/GLOBAL layer, never "every
  # tenant". The old `nil -> query` arm handed the unscoped query straight
  # through, so `count_for_ticket/3` counted `mediaAsset` rows across every
  # workspace whenever the caller resolved none. `:shared_only` resolves to
  # `where(is_nil(x.workspace_id))`, which is what a NULL-workspace install
  # actually wants.
  defp scope_workspace(query, scope) do
    Content.Scope.scope_to_workspace_or_global(
      query,
      Keyword.get(scope, :workspace_id) || :shared_only,
      Keyword.get(scope, :project_id)
    )
  end

  defp default_filename(mime) do
    ext =
      case MIME.extensions(mime) do
        [ext | _] -> "." <> ext
        _ -> ""
      end

    "attachment" <> ext
  end
end
