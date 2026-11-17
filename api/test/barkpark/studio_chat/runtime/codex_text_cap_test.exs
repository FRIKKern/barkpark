defmodule Barkpark.StudioChat.Runtime.CodexTextCapTest do
  @moduledoc """
  task-ed920e5459df0ab5 — codex/protocol.ex cuts a provider's text to 2,000
  graphemes AND 8,000 bytes, at a valid UTF-8 boundary. A grapheme can be any
  number of bytes: one letter with 200,000 combining marks is one grapheme and
  400 KB, so the grapheme cut alone let it through whole.
  """
  use ExUnit.Case, async: true

  alias Barkpark.StudioChat.Runtime.Codex.Protocol

  @mark "́"
  @context %{session_id: "s", thread_id: "th-1", turn_id: "t-1", sequence: 1}

  test "one letter with 200,000 combining marks is cut to 8,000 bytes of valid UTF-8" do
    huge = "x" <> String.duplicate(@mark, 200_000)

    for text <- [
          Protocol.process_failed(@context, 1, huge).error["detail"],
          Protocol.malformed(@context, huge).error["detail"],
          error_message(huge)
        ] do
      assert byte_size(text) <= 8_000
      assert String.valid?(text)
      assert String.starts_with?(text, "x" <> @mark)
    end
  end

  test "a cut that lands inside a character backs off to the character before it" do
    # 1 + 4,000 x 2 bytes = 8,001: byte 8,000 is the first half of the last mark.
    text = "x" <> String.duplicate(@mark, 4_000)

    assert Protocol.process_failed(@context, 1, text).error["detail"] ==
             "x" <> String.duplicate(@mark, 3_999)
  end

  test "the 2,000-grapheme cut still holds, and short text is unchanged" do
    assert error_message(String.duplicate("y", 10_000)) == String.duplicate("y", 2_000)
    assert error_message("Reconnecting... 1/5") == "Reconnecting... 1/5"
    assert Protocol.process_failed(@context, 1, nil).error["detail"] == nil
  end

  defp error_message(message) do
    Protocol.normalize(
      %{"method" => "error", "params" => %{"error" => %{"message" => message}}},
      @context
    ).error["message"]
  end
end
