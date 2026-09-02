defmodule Barkpark.StudioChat.Attachments do
  @moduledoc """
  The ONE chat-owned attachment store seam — the single entry point both
  surfaces (Studio LiveView and the `/v1/chat` transport) put bytes through and
  read references out of.

  ## Why this module exists at all (charter D16 / D6)

  Attachments must NEVER ride the media plugin. `GET /media/files/*` is
  any-token-public by design (`Plugins.Media.Access` grants a "private" asset to
  any valid bearer, and a share scope grants an anonymous one) — that is the
  exact read boundary the chat engine's "no HTTP route ever over chat bytes"
  design was built to avoid. Chat bytes are private conversation content: their
  read gate has to be the SAME tenant oracle every other
  `/v1/chat/sessions/:id` route uses, not the media plugin's broader one.

  So the bytes live in the chat-owned store (`StudioChat.store_attachment/3` —
  content-addressed under `<attachments_dir>/<session_id>/<sha256>`), and the
  only way to read them over HTTP is
  `GET /v1/chat/sessions/:id/attachments/:attachment_id`, which resolves the
  session through `fetch_scoped/2` FIRST — a wrong-tenant read joins the
  not-found oracle exactly like every other id route.

  ## The reference shape — one shape, both surfaces

  A stored attachment has two representations and they are deliberately
  different:

    * the **pointer** (`pointer_json/1`) is the SERVER-SIDE jsonb persisted on
      the message row: `{path, media_type, sha256, byte_size}`. `path` is the
      relative store path (`<session_id>/<sha256>`) — a filesystem detail that
      must never leave the server.

    * the **reference** (`reference/2`) is the WIRE shape every client reads:
      `{id, media_type, byte_size, url}`. It carries NO local path, NO bearer
      token, and NO bytes — just an opaque id and the chat-owned URL that will
      serve it to a caller who can already reach the session.

  `ChatController.message_json/1` projects `metadata["attachments"]` through
  `references/2`, so the transcript on the wire is structurally unable to carry
  the store path. `bp chat` decodes that same reference; the Studio LiveView
  writes the pointer through `pointer_json/1` here, so there is one writer and
  one projector rather than a per-surface fork.

  ## Identity

  `id` is the content address itself (the sha256 hex of the bytes) — the store
  is content-addressed, so that is the stable, natural handle, and it is opaque
  with respect to the STORAGE LAYOUT: no directory, no session id, no filename,
  no token. Id secrecy is explicitly NOT the fence. The fence is the session leg
  of the URL: every read runs the tenant oracle on `:id` before this module is
  reached, and the bytes only exist under a session's own directory, so a
  guessed id with no session access is a 404. Keeping the id content-derived
  also means every attachment the Studio composer has ALREADY written (its
  pointers carry `sha256` and nothing else) is readable through the new route —
  a random-id scheme would have stranded them.

  ## Media types are SNIFFED, never trusted

  The accepted set is png/jpeg/gif/webp (charter D25). The type is derived from
  the bytes' magic prefix, not from anything the caller declared: an upload whose
  bytes are not one of those four is refused. That closes the obvious hazard of a
  chat-owned byte route — an `image/svg+xml` or `text/html` payload echoed back
  under a caller-chosen content type is a stored-XSS primitive, and a sniffed
  allowlist makes it unrepresentable rather than merely discouraged.
  """

  alias Barkpark.StudioChat

  # The accepted image set (charter D25). Kept in step with the Studio
  # composer's `allow_upload` accept-list.
  @media_types ~w(image/png image/jpeg image/gif image/webp)

  # Per-attachment byte ceiling — the SAME 3 MB the Studio composer's
  # allow_upload enforces (base64 inflates x4/3, so the provider wire payload
  # stays under the ~5 MB-per-image cap). This is the chat limit, NOT the
  # endpoint-wide 100 MB parser ceiling.
  @max_bytes 3_000_000

  @doc "The accepted media types (png | jpeg | gif | webp)."
  @spec media_types() :: [String.t()]
  def media_types, do: @media_types

  @doc "The per-attachment byte ceiling."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Store one attachment's bytes for `session_id` and return the SERVER-SIDE
  pointer map `%{path, media_type, sha256, byte_size}`.

  The media type is sniffed from the bytes (never taken from the caller); bytes
  that are not one of the four accepted images are refused with
  `{:error, :unsupported_media_type}`, and anything over `max_bytes/0` with
  `{:error, :too_large}`. Empty bytes are `{:error, :empty}`.

  This is the ONE writer both surfaces use — the Studio composer's
  `consume_attachments/1` and the transport's upload route both land here, so
  "Studio uploads go to the same content-addressed store" is true by
  construction rather than by convention.
  """
  @spec put(String.t(), binary()) ::
          {:ok, map()} | {:error, :empty | :too_large | :unsupported_media_type | term()}
  def put(session_id, bytes) when is_binary(session_id) and is_binary(bytes) do
    cond do
      bytes == "" ->
        {:error, :empty}

      byte_size(bytes) > @max_bytes ->
        {:error, :too_large}

      true ->
        case sniff_media_type(bytes) do
          nil -> {:error, :unsupported_media_type}
          media_type -> StudioChat.store_attachment(session_id, bytes, media_type)
        end
    end
  end

  def put(_, _), do: {:error, :unsupported_media_type}

  @doc """
  Read one attachment back by its opaque `attachment_id`, scoped to
  `session_id`.

  Returns `{:ok, %{id, media_type, byte_size, sha256, bytes}}` or
  `{:error, :missing}`. The id must be a 64-character lowercase sha256 hex — any
  other shape (a traversal attempt, a sidecar-looking name, an absolute path) is
  rejected BEFORE the store is touched, so this can never be walked out of the
  session's own directory even before `StudioChat.read_attachment/1`'s own
  two-segment guard runs.

  The media type is sniffed from the bytes on the way out too, so what the route
  reports always describes what it is actually serving.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, :missing}
  def fetch(session_id, attachment_id)
      when is_binary(session_id) and is_binary(attachment_id) do
    if valid_id?(attachment_id) do
      case StudioChat.read_attachment(Path.join(session_id, attachment_id)) do
        {:ok, bytes} ->
          {:ok,
           %{
             id: attachment_id,
             sha256: attachment_id,
             media_type: sniff_media_type(bytes) || "application/octet-stream",
             byte_size: byte_size(bytes),
             bytes: bytes
           }}

        {:error, :missing} ->
          {:error, :missing}
      end
    else
      {:error, :missing}
    end
  end

  def fetch(_, _), do: {:error, :missing}

  @doc """
  True when `id` is a well-formed opaque attachment id (64 lowercase hex chars).
  """
  @spec valid_id?(term()) :: boolean()
  def valid_id?(id) when is_binary(id),
    do: byte_size(id) == 64 and String.match?(id, ~r/\A[0-9a-f]{64}\z/)

  def valid_id?(_), do: false

  @doc """
  The jsonb pointer persisted on a message row — `path`/`media_type`/`sha256`/
  `byte_size` ONLY, never the bytes (charter D7/D25). Accepts the atom-keyed map
  `put/2` returns and normalises it to string keys.
  """
  @spec pointer_json(map()) :: map()
  def pointer_json(pointer) when is_map(pointer) do
    %{
      "path" => get(pointer, :path),
      "media_type" => get(pointer, :media_type),
      "sha256" => get(pointer, :sha256),
      "byte_size" => get(pointer, :byte_size)
    }
  end

  @doc """
  Project ONE stored pointer to the WIRE reference: `{id, media_type, byte_size,
  url}`.

  The store `path` is DROPPED here — this is the single place the server decides
  what a client is allowed to learn about an attachment, and a filesystem path is
  not on that list. Returns `nil` for a pointer with no usable content address
  (an older/thinner row), so a malformed pointer degrades to an omitted
  reference rather than a half-formed one.
  """
  @spec reference(map(), String.t()) :: map() | nil
  def reference(pointer, session_id) when is_map(pointer) and is_binary(session_id) do
    id = content_id(pointer)

    if valid_id?(id) do
      %{
        id: id,
        media_type: media_type_or_default(get(pointer, :media_type)),
        byte_size: byte_size_or_nil(get(pointer, :byte_size)),
        url: url(session_id, id)
      }
    end
  end

  def reference(_, _), do: nil

  @doc """
  Project a message row's `metadata["attachments"]` list to the wire reference
  list, or `nil` when the row carries none (so the message JSON simply has no
  `attachments` key rather than an empty one).
  """
  @spec references(map() | nil, String.t()) :: [map()] | nil
  def references(metadata, session_id) when is_binary(session_id) do
    case Map.get(metadata || %{}, "attachments") do
      list when is_list(list) ->
        case list |> Enum.map(&reference(&1, session_id)) |> Enum.reject(&is_nil/1) do
          [] -> nil
          refs -> refs
        end

      _ ->
        nil
    end
  end

  def references(_, _), do: nil

  @doc """
  The chat-owned read URL for an attachment. Relative and token-free by design:
  the caller attaches its OWN Authorization header, so a bearer token can never
  be baked into a transcript (charter criterion — no tokens in the message
  payload).
  """
  @spec url(String.t(), String.t()) :: String.t()
  def url(session_id, id), do: "/v1/chat/sessions/#{session_id}/attachments/#{id}"

  # ── media-type sniffing ─────────────────────────────────────────────────────
  #
  # Magic prefixes for the four accepted images. Anything else is nil — which
  # `put/2` turns into a refusal, so an SVG/HTML/script payload can never enter
  # the chat store and can never be served back out of it.
  defp sniff_media_type(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp sniff_media_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp sniff_media_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp sniff_media_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp sniff_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp sniff_media_type(_), do: nil

  # ── pointer helpers ─────────────────────────────────────────────────────────

  # The content address off a pointer: prefer the explicit `sha256`, fall back to
  # the leaf of `path` (`<session_id>/<sha256>`) so a pointer written before
  # sha256 was recorded still yields an id.
  defp content_id(pointer) do
    case get(pointer, :sha256) do
      sha when is_binary(sha) -> sha
      _ -> path_leaf(get(pointer, :path))
    end
  end

  defp path_leaf(path) when is_binary(path), do: path |> Path.split() |> List.last()
  defp path_leaf(_), do: nil

  defp media_type_or_default(mt) when mt in @media_types, do: mt
  defp media_type_or_default(_), do: "application/octet-stream"

  defp byte_size_or_nil(n) when is_integer(n) and n >= 0, do: n
  defp byte_size_or_nil(_), do: nil

  # Pointers arrive atom-keyed from `put/2` and string-keyed from jsonb.
  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
