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

  A reference has exactly three keys: `id` (the sha256 hex of the decoded bytes,
  which is the chat store's content address), `media_type` and `byte_size`. No
  file name, store path, url or token.

  The payload's `content` becomes the text alone: the text blocks joined by a
  newline, which is what the host already reduces a block list to. Content that
  is already a string passes through untouched and gains no `attachments` key.

  It fails closed. A block that is neither a text block nor a base64 image of an
  accepted type, or image data that is not base64, refuses the whole turn with
  `{:error, :invalid_turn_content}`: nothing is leased and nothing is dropped
  without a word.
  """

  alias Barkpark.StudioChat.Attachments

  @type attachment_ref :: %{id: String.t(), media_type: String.t(), byte_size: non_neg_integer()}

  @doc """
  Rewrite a send_turn payload for a registered host. A block-list `content`
  becomes `%{content: text, attachments: [reference]}` (the `attachments` key is
  present only when there is at least one image); a string `content` is
  returned unchanged.
  """
  @spec to_references(map()) :: {:ok, map()} | {:error, :invalid_turn_content}
  def to_references(%{content: blocks} = payload) when is_list(blocks) do
    with {:ok, texts, refs} <- split(blocks, [], []) do
      payload = Map.put(payload, :content, Enum.join(texts, "\n"))
      {:ok, if(refs == [], do: payload, else: Map.put(payload, :attachments, refs))}
    end
  end

  def to_references(payload), do: {:ok, payload}

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

  defp split([_unknown | _rest], _texts, _refs), do: {:error, :invalid_turn_content}

  defp reference(%{"type" => "base64", "media_type" => media_type, "data" => data})
       when is_binary(media_type) and is_binary(data) do
    with true <- media_type in Attachments.media_types(),
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

  defp reference(_source), do: :error
end
