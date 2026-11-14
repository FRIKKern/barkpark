defmodule BarkparkWeb.Studio.ChatAttachmentChip do
  @moduledoc """
  How the Studio chat replays one attachment pointer from a user row
  (`/papers/chat-host-file-attachments-plan`, T2).

  An image pointer is read from the chat store and drawn as an `<img>` with a
  data URI, as before. A file pointer (text or PDF, sent through `/v1/chat` by
  another client) is drawn as a chip with its name and byte size, and its bytes
  are never read: a 3 MB text file must not become a 4 MB data URI in the
  socket, and a browser cannot draw it as an image anyway.

  `ChatLive.replay_image/1` delegates to `replay/1`, and the user-row template
  renders a `%{file: ...}` item with `chip/1`. The Studio composer itself still
  sends images only.
  """

  use Phoenix.Component

  use Gettext, backend: BarkparkWeb.Gettext

  alias Barkpark.StudioChat
  alias Barkpark.StudioChat.Attachments

  @doc """
  The replay item for one stored pointer: `%{data_uri: uri}` for an image whose
  bytes are in the store, `%{missing: true}` for an image whose bytes are gone
  or a malformed pointer, and `%{file: %{name, byte_size}}` for any other type,
  built from the pointer alone.
  """
  @spec replay(term()) :: map()
  def replay(%{"path" => path, "media_type" => media_type} = pointer) when is_binary(path) do
    if media_type in Attachments.media_types(),
      do: image(path, media_type),
      else: %{file: %{name: name(pointer), byte_size: byte_size_of(pointer)}}
  end

  def replay(_), do: %{missing: true}

  defp image(path, media_type) do
    case StudioChat.read_attachment(path) do
      {:ok, bytes} -> %{data_uri: "data:#{media_type};base64,#{Base.encode64(bytes)}"}
      {:error, :missing} -> %{missing: true}
    end
  end

  # A pointer carries a name once a message names its file (T4). Rows without
  # one, and any value that is not a non-empty string, show "File".
  defp name(%{"name" => name}) when is_binary(name) and name != "", do: name
  defp name(_), do: nil

  defp byte_size_of(%{"byte_size" => n}) when is_integer(n) and n >= 0, do: n
  defp byte_size_of(_), do: nil

  @doc "A file attachment on a user row: its name and its size."
  attr :file, :map, required: true

  def chip(assigns) do
    ~H"""
    <div
      data-role="attachment-file"
      class="text-xs"
      style="display: flex; flex-direction: column; gap: 2px; max-width: 220px; border: 1px solid var(--border-muted); border-radius: 10px; padding: 10px 14px;"
    >
      <span style="overflow: hidden; text-overflow: ellipsis; white-space: nowrap;" title={@file.name}>
        {@file.name || gettext("File")}
      </span>
      <span :if={@file.byte_size} class="text-dim">{size_label(@file.byte_size)}</span>
    </div>
    """
  end

  @doc """
  A byte count as people read it: `512 B`, `12.3 KB`, `2.9 MB`, in powers of
  1000 like the store's 3 MB cap.
  """
  @spec size_label(non_neg_integer()) :: String.t()
  def size_label(n) when n < 1000, do: "#{n} B"
  def size_label(n) when n < 1_000_000, do: "#{one_decimal(n / 1000)} KB"
  def size_label(n), do: "#{one_decimal(n / 1_000_000)} MB"

  defp one_decimal(x), do: :erlang.float_to_binary(x, decimals: 1)
end
