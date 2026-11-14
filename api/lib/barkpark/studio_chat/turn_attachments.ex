defmodule Barkpark.StudioChat.TurnAttachments do
  @moduledoc """
  Turns a send_turn's content into what a registered host is leased: the text,
  plus one reference per image. The image bytes never ride the leased command.

  Studio hands `Runtime.send_turn/3` a block list: text blocks and base64 image
  blocks (charter D25). A managed claude session writes that list to claude's
  stdin as is. A registered host instead receives the command through
  `ChatHosts.Transport` and the host's poll response, so the bytes would sit in
  server memory and cross the wire, and a host that keeps only text drops them.
  Each image is therefore replaced by a reference to the chat-owned store. The
  read a host uses to fetch those bytes with its own credential, through the
  lease it holds, is planned in the Paper chat-host-attachments-plan.

  A host is only leased references it says it can take: `admit/3` checks each
  reference's media type against the host's advertised
  `providers.<provider>.attachments` list.

  An image reference has exactly three keys: `id` (the sha256 hex of the decoded
  bytes, which is the chat store's content address), `media_type` and
  `byte_size`. No file name, store path, url or token.

  A file (`/papers/chat-host-file-attachments-plan`) arrives as a document
  block, `{"type": "document", "source": {"type": "base64", "media_type",
  "data"}, "title": name}`, with a `text/plain` or `application/pdf` type. Its
  reference has the same three keys plus `name`, the block's title, which must
  pass `AttachmentName.valid?/1`. The host writes the file under a path built
  from the id, never from the name.

  The payload's `content` becomes the text alone: the text blocks joined by a
  newline, which is what the host already reduces a block list to. Content that
  is already a string passes through untouched and gains no `attachments` key.

  It fails closed. A block that is not a text block, a base64 image of an image
  type, or a base64 document of a file type with a valid name, or data that is
  not base64, refuses the whole turn with `{:error, :invalid_turn_content}`:
  nothing is leased and nothing is dropped without a word.
  """

  alias Barkpark.StudioChat.{AttachmentName, Attachments}

  @type attachment_ref :: %{
          required(:id) => String.t(),
          required(:media_type) => String.t(),
          required(:byte_size) => non_neg_integer(),
          optional(:name) => String.t()
        }

  @doc """
  Rewrite a send_turn payload for a registered host. A block-list `content`
  becomes `%{content: text, attachments: [reference]}` (the `attachments` key is
  present only when there is at least one image or file); a string `content`
  is returned unchanged.
  """
  @spec to_references(map()) :: {:ok, map()} | {:error, :invalid_turn_content}
  def to_references(%{content: blocks} = payload) when is_list(blocks) do
    with {:ok, texts, refs} <- split(blocks, [], []) do
      payload = Map.put(payload, :content, Enum.join(texts, "\n"))
      {:ok, if(refs == [], do: payload, else: Map.put(payload, :attachments, refs))}
    end
  end

  def to_references(payload), do: {:ok, payload}

  @doc """
  Whether `host` may be leased `command`. A send_turn that carries references
  needs every reference's media type in the host's
  `capabilities.providers[provider].attachments`. Otherwise it is refused with
  `{:error, {:host_cannot_receive_attachments, provider}}` and the caller
  leases nothing, so a host binary that would drop the image is never sent it.
  Any other command, and a send_turn without references, is admitted.
  """
  @spec admit(map(), String.t() | atom(), map()) ::
          :ok | {:error, {:host_cannot_receive_attachments, String.t()}}
  def admit(host, provider, %{operation: :send_turn, payload: %{attachments: [_ | _] = refs}}) do
    provider = to_string(provider)
    # The codex adapter has no file path: a file is never leased to codex, even
    # when a host lists file types under its codex entry.
    codex_refused = if provider == "codex", do: Attachments.file_types(), else: []
    accepted = accepted_types(host, provider) -- codex_refused

    if Enum.all?(refs, &(&1.media_type in accepted)),
      do: :ok,
      else: {:error, {:host_cannot_receive_attachments, provider}}
  end

  def admit(_host, _provider, _command), do: :ok

  # Fails closed: a missing or malformed capability reads as "takes none".
  defp accepted_types(host, provider) do
    with caps when is_map(caps) <- field(host, "capabilities"),
         providers when is_map(providers) <- field(caps, "providers"),
         metadata when is_map(metadata) <- provider_metadata(providers, provider),
         types when is_list(types) <- field(metadata, "attachments") do
      types
    else
      _ -> []
    end
  end

  defp provider_metadata(providers, provider),
    do:
      Enum.find_value(providers, fn {name, meta} -> if to_string(name) == provider, do: meta end)

  # Stored capabilities are string-keyed JSON; a host struct and in-memory test
  # hosts use atom keys.
  defp field(map, key),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key)))

  defp split([], texts, refs), do: {:ok, Enum.reverse(texts), Enum.reverse(refs)}

  defp split([%{"type" => "text", "text" => text} | rest], texts, refs) when is_binary(text) do
    texts = if text == "", do: texts, else: [text | texts]
    split(rest, texts, refs)
  end

  defp split([%{"type" => "image", "source" => source} | rest], texts, refs) do
    case reference(source) do
      {:ok, ref} -> split(rest, texts, [ref | refs])
      :error -> {:error, :invalid_turn_content}
    end
  end

  defp split([%{"type" => "document", "source" => source} = block | rest], texts, refs) do
    with true <- AttachmentName.valid?(block["title"]),
         {:ok, ref} <- reference(source, Attachments.file_types()) do
      split(rest, texts, [Map.put(ref, :name, block["title"]) | refs])
    else
      _ -> {:error, :invalid_turn_content}
    end
  end

  defp split([_unknown | _rest], _texts, _refs), do: {:error, :invalid_turn_content}

  defp reference(source), do: reference(source, Attachments.media_types())

  defp reference(%{"type" => "base64", "media_type" => media_type, "data" => data}, accepted)
       when is_binary(media_type) and is_binary(data) do
    with true <- media_type in accepted,
         {:ok, bytes} <- Base.decode64(data) do
      {:ok,
       %{
         id: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
         media_type: media_type,
         byte_size: byte_size(bytes)
       }}
    else
      _ -> :error
    end
  end

  defp reference(_source, _accepted), do: :error
end
