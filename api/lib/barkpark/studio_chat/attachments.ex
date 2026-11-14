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

  The accepted set is the four images png/jpeg/gif/webp (charter D25) and two
  file types (`/papers/chat-host-file-attachments-plan`): `application/pdf`
  when the bytes start with `%PDF-`, and `text/plain` when they are valid UTF-8
  with no NUL byte. The type is derived from the bytes, not from anything the
  caller declared, and anything else is refused. Every text is `text/plain`:
  HTML, SVG and JavaScript are never stored or reported under their own type,
  and the only HTTP reads answer a JSON envelope with the bytes in base64, so
  no browser ever receives these bytes as a document. That keeps the stored-XSS
  shape of a chat-owned byte route unrepresentable.

  Zip and everything built on it, executables (PE, ELF, Mach-O), gzip, UTF-16
  text and invalid UTF-8 all fail both rules and are refused. `media_types/0`
  stays the four images: the Studio composer (`put_image/2`), the leased
  reference and the message body read it, and none of them takes a file yet.
  """

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.AttachmentName

  # The accepted image set (charter D25). Kept in step with the Studio
  # composer's `allow_upload` accept-list.
  @media_types ~w(image/png image/jpeg image/gif image/webp)

  # The sniffed non-image types (`sniff_file_type/1`).
  @file_types ~w(text/plain application/pdf)

  # Per-attachment byte ceiling — the SAME 3 MB the Studio composer's
  # allow_upload enforces (base64 inflates x4/3, so the provider wire payload
  # stays under the ~5 MB-per-image cap). This is the chat limit, NOT the
  # endpoint-wide 100 MB parser ceiling.
  @max_bytes 3_000_000

  @doc "The accepted image types (png | jpeg | gif | webp)."
  @spec media_types() :: [String.t()]
  def media_types, do: @media_types

  @doc "The accepted file types besides images (text/plain | application/pdf)."
  @spec file_types() :: [String.t()]
  def file_types, do: @file_types

  @doc "The per-attachment byte ceiling."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc """
  Store one attachment's bytes for `session_id` and return the SERVER-SIDE
  pointer map `%{path, media_type, sha256, byte_size}`.

  The media type is sniffed from the bytes (never taken from the caller); bytes
  that are not one of the four images, UTF-8 text or a PDF are refused with
  `{:error, :unsupported_media_type}`, and anything over `max_bytes/0` with
  `{:error, :too_large}`. Empty bytes are `{:error, :empty}`.

  This is the writer the transport's upload route uses. The Studio composer
  writes through `put_image/2`, the same store with the images-only rule, so
  "Studio uploads go to the same content-addressed store" is true by
  construction rather than by convention.
  """
  @spec put(String.t(), binary()) ::
          {:ok, map()} | {:error, :empty | :too_large | :unsupported_media_type | term()}
  def put(session_id, bytes), do: put(session_id, bytes, @media_types ++ @file_types)

  @doc """
  `put/2` limited to the four images. The Studio composer's upload accepts only
  images, and the browser's declared type is caller input, so a text file
  renamed `x.png` must still be refused here rather than stored as text and
  sent to the provider as an image block.
  """
  @spec put_image(String.t(), binary()) ::
          {:ok, map()} | {:error, :empty | :too_large | :unsupported_media_type | term()}
  def put_image(session_id, bytes), do: put(session_id, bytes, @media_types)

  defp put(session_id, bytes, accepted) when is_binary(session_id) and is_binary(bytes) do
    cond do
      bytes == "" ->
        {:error, :empty}

      byte_size(bytes) > @max_bytes ->
        {:error, :too_large}

      true ->
        media_type = sniff_media_type(bytes)

        if media_type in accepted,
          do: StudioChat.store_attachment(session_id, bytes, media_type),
          else: {:error, :unsupported_media_type}
    end
  end

  defp put(_, _, _), do: {:error, :unsupported_media_type}

  @doc """
  Read one attachment back by its opaque `attachment_id`, scoped to
  `session_id`.

  Returns `{:ok, %{id, path, media_type, byte_size, sha256, bytes}}` or
  `{:error, :missing}`. Minus `id` and `bytes`, that is the pointer `put/2`
  returns, so `pointer_json/1` of a fetched attachment is the row pointer a
  Studio send of the same bytes persists. The id must be a 64-character
  lowercase sha256 hex — any other shape (a traversal attempt, a sidecar-looking
  name, an absolute path) is rejected BEFORE the store is touched, so this can
  never be walked out of the session's own directory even before
  `StudioChat.read_attachment/1`'s own two-segment guard runs.

  The media type is sniffed from the bytes on the way out too, so what the route
  reports always describes what it is actually serving.
  """
  @spec fetch(String.t(), String.t()) :: {:ok, map()} | {:error, :missing}
  def fetch(session_id, attachment_id)
      when is_binary(session_id) and is_binary(attachment_id) do
    if valid_id?(attachment_id) do
      path = Path.join(session_id, attachment_id)

      case StudioChat.read_attachment(path) do
        {:ok, bytes} ->
          {:ok,
           %{
             id: attachment_id,
             path: path,
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
  `byte_size`, plus `name` when the attachment was sent with one, and never the
  bytes (charter D7/D25). Accepts the atom-keyed map `put/2` returns and
  normalises it to string keys.
  """
  @spec pointer_json(map()) :: map()
  def pointer_json(pointer) when is_map(pointer) do
    %{
      "path" => get(pointer, :path),
      "media_type" => get(pointer, :media_type),
      "sha256" => get(pointer, :sha256),
      "byte_size" => get(pointer, :byte_size)
    }
    |> put_name("name", get(pointer, :name))
  end

  @doc """
  The user turn's content-block list, the one both surfaces hand
  `Runtime.send_turn/3`: a text block (omitted when `text` is empty, an
  attachment-only turn) followed by one block per attachment, in order. An
  image is a base64 image block (charter D25 wire shape). A text file or PDF is
  a base64 document block titled with its `:name`, the Messages API shape; only
  `BarkparkWeb.ChatUserTurn` builds those, for a registered-host session. Each
  attachment is a map with `:media_type` and `:bytes`, as `fetch/2` returns and
  the Studio composer carries after `put_image/2`.
  """
  @spec user_content(String.t(), [map()]) :: [map()]
  def user_content(text, attachments) when is_list(attachments) do
    text_blocks = if text == "", do: [], else: [%{"type" => "text", "text" => text}]
    text_blocks ++ Enum.map(attachments, &attachment_block/1)
  end

  defp attachment_block(%{media_type: type} = a) when type in @file_types do
    %{"type" => "document", "source" => base64_source(a), "title" => Map.fetch!(a, :name)}
  end

  defp attachment_block(a), do: %{"type" => "image", "source" => base64_source(a)}

  defp base64_source(a),
    do: %{"type" => "base64", "media_type" => a.media_type, "data" => Base.encode64(a.bytes)}

  @doc """
  Project ONE stored pointer to the WIRE reference: `{id, media_type, byte_size,
  url}`, plus `name` when the pointer carries a valid one.

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
      |> put_name(:name, get(pointer, :name))
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
  # Magic prefixes for the four accepted images, then `%PDF-`, then UTF-8 text.
  # Anything else is nil, which `put/3` turns into a refusal. An SVG, HTML or
  # script payload sniffs as text/plain and is only ever reported as that.
  defp sniff_media_type(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _::binary>>), do: "image/png"
  defp sniff_media_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: "image/jpeg"
  defp sniff_media_type(<<"GIF87a", _::binary>>), do: "image/gif"
  defp sniff_media_type(<<"GIF89a", _::binary>>), do: "image/gif"
  defp sniff_media_type(<<"RIFF", _size::binary-size(4), "WEBP", _::binary>>), do: "image/webp"
  defp sniff_media_type(<<"%PDF-", _::binary>>), do: "application/pdf"
  defp sniff_media_type(bytes), do: if(text?(bytes), do: "text/plain")

  # Valid UTF-8 with no NUL byte. UTF-16 fails both legs (its byte order mark
  # is not UTF-8, and its ASCII carries a NUL per character), and every zip,
  # PE, ELF and Mach-O header holds a NUL or a byte that is not UTF-8.
  defp text?(bytes), do: String.valid?(bytes) and not String.contains?(bytes, <<0>>)

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

  defp media_type_or_default(mt) when mt in @media_types or mt in @file_types, do: mt
  defp media_type_or_default(_), do: "application/octet-stream"

  defp byte_size_or_nil(n) when is_integer(n) and n >= 0, do: n
  defp byte_size_or_nil(_), do: nil

  # A name rides a pointer or a reference only when it passes the name rule,
  # so a row written by hand cannot put a newline or a path on the wire.
  defp put_name(map, key, name),
    do: if(AttachmentName.valid?(name), do: Map.put(map, key, name), else: map)

  # Pointers arrive atom-keyed from `put/2` and string-keyed from jsonb.
  defp get(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end
end
