defmodule Barkpark.StudioChat.AttachmentName do
  @moduledoc """
  The rule for a chat file attachment's name (`/papers/chat-host-file-attachments-plan`).

  A file sent to a registered host carries the name the person gave it. The
  name rides the leased command and the host quotes it into claude's prompt,
  so it must not be able to break a line, reorder text, or look like a path.
  A name is refused, never cleaned, when it:

    * is empty or longer than 255 bytes;
    * is not valid UTF-8;
    * holds a Unicode control (Cc) or format (Cf) character, which covers
      newline, tab, NUL, DEL, the zero-width characters and the bidi
      overrides such as U+202E;
    * holds `/` or `\\`;
    * is `.` or `..`.

  The server checks it twice: when a message names a file
  (`BarkparkWeb.ChatUserTurn`) and when a turn is leased to a host
  (`Barkpark.StudioChat.TurnAttachments`). The Go host checks the same rule
  again before it uses the name. The name is never part of a file path on
  either side.
  """

  @max_bytes 255

  @doc "The longest name, in bytes."
  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @doc "True when `name` may be used as an attachment's name."
  @spec valid?(term()) :: boolean()
  def valid?(name) when is_binary(name) do
    name != "" and byte_size(name) <= @max_bytes and String.valid?(name) and
      name not in [".", ".."] and not String.contains?(name, ["/", "\\"]) and
      not Regex.match?(~r/[\p{Cc}\p{Cf}]/u, name)
  end

  def valid?(_), do: false
end
