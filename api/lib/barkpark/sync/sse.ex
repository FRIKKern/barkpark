defmodule Barkpark.Sync.SSE do
  @moduledoc """
  Pure Server-Sent-Events frame parser — THE deterministic wire seam for the
  pull-sync subsystem. No network, no DB, no process state: a single function
  from an accumulated byte buffer to `{events, rest}`.

  Wire contract (the producer is `BarkparkWeb.ListenController.format_event/2`):

    * frames are delimited by a BLANK LINE (`\\n\\n`);
    * within a frame, fields are `id: <n>`, `event: <name>`, `data: <text>`;
    * a line beginning with `:` is a COMMENT (the `: keepalive\\n\\n` liveness
      ping) and carries no field;
    * exactly ONE leading space after the field colon is stripped;
    * multiple `data:` lines in a frame are joined with `\\n` before decoding;
    * the `Last-Event-ID` to resume from is taken ONLY from the `id:` line.

  Only `event: mutation` frames whose joined `data` is valid JSON become
  events; `welcome` and keepalive frames are silently dropped (they neither
  yield an event nor advance the cursor). A frame split across two TCP/HTTP
  chunks is buffered: the incomplete trailing remainder is returned as `rest`
  and must be prepended to the next chunk before the next call.
  """

  @typedoc """
  One decoded mutation event. `:id` is the SSE `id:` line (the resume cursor,
  `nil` if absent); `:envelope` is the decoded JSON mutation envelope
  (`%{"eventId", "mutation", "type", "documentId", "rev", "previousRev",
  "result", "syncTags"}`).
  """
  @type event :: %{id: non_neg_integer() | nil, type: String.t(), envelope: map()}

  @doc """
  Split an accumulated buffer into complete decoded mutation events and the
  carried-over incomplete remainder.
  """
  @spec parse_frames(binary()) :: {[event()], binary()}
  def parse_frames(buffer) when is_binary(buffer) do
    {frames, rest} = split_frames(buffer)
    events = frames |> Enum.map(&parse_frame/1) |> Enum.reject(&is_nil/1)
    {events, rest}
  end

  # Split on the blank-line delimiter. The LAST segment is always the
  # (possibly empty) incomplete remainder — a buffer ending in `\n\n` yields a
  # trailing "" remainder, which is correct (nothing carried forward).
  defp split_frames(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [rest]} = Enum.split(parts, length(parts) - 1)
    {complete, rest}
  end

  defp parse_frame(frame) do
    {id, type, data_lines} =
      frame
      |> String.split("\n")
      |> Enum.reduce({nil, nil, []}, fn line, {id, type, data} = acc ->
        cond do
          line == "" ->
            acc

          # A line starting with ":" is an SSE comment (keepalive) — no field.
          String.starts_with?(line, ":") ->
            acc

          true ->
            case parse_field(line) do
              {"id", v} -> {parse_int(v), type, data}
              {"event", v} -> {id, v, data}
              {"data", v} -> {id, type, [v | data]}
              _ -> acc
            end
        end
      end)

    data = data_lines |> Enum.reverse() |> Enum.join("\n")

    if type == "mutation" and data != "" do
      case Jason.decode(data) do
        {:ok, envelope} when is_map(envelope) -> %{id: id, type: type, envelope: envelope}
        _ -> nil
      end
    end
  end

  # Split a field line on the FIRST colon; strip exactly one leading space from
  # the value (per the SSE spec).
  defp parse_field(line) do
    case String.split(line, ":", parts: 2) do
      [field, value] -> {field, strip_leading_space(value)}
      [field] -> {field, ""}
    end
  end

  defp strip_leading_space(" " <> rest), do: rest
  defp strip_leading_space(v), do: v

  defp parse_int(v) when is_binary(v) do
    case Integer.parse(String.trim(v)) do
      {n, _} -> n
      :error -> nil
    end
  end
end
