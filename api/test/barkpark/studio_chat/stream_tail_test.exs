defmodule Barkpark.StudioChat.StreamTailTest do
  @moduledoc """
  The FIRST unit corpus on the progressive-streaming boundary (charter D62 /
  chat-TUI D81 clause 2). Every case here is a shape the old substring counter
  (`rem(length(:binary.matches(prefix, "```")), 2) == 0`) got WRONG in
  production — reverting the fold to that counter REDS this file, which is how
  these tests are proven able to fail.

  The renderer is injected, so the corpus asserts on the raw stable PREFIX
  (`& &1`) instead of on HTML: the boundary law is the thing under test.
  """
  # async: FALSE deliberately. The "display cap" describe block swaps
  # :max_streaming_display_bytes through Application.put_env/3, which writes ONE
  # value for the WHOLE NODE — under async: true that swap is in force for every
  # other async test running at that instant (AsyncGlobalSeamGuardTest catches
  # exactly this, and did). The cap is read via StreamTail.max_streaming_display_bytes/0
  # off Application env with no injection seam, so serialising this pure-unit module
  # is the honest fix rather than widening the guard.
  use ExUnit.Case, async: false

  alias Barkpark.StudioChat.StreamTail

  # Drive the state machine the way the LiveView does: one delta at a time.
  defp stream(deltas) when is_list(deltas) do
    Enum.reduce(deltas, nil, fn delta, state ->
      StreamTail.advance(state, delta, &Function.identity/1)
    end)
  end

  defp stream(text) when is_binary(text), do: stream([text])

  defp boundary(deltas), do: stream(deltas).stable_len

  # Every partitioning of the same bytes into `n` deltas.
  defp partition(text, n, seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 3})
    size = byte_size(text)

    cuts =
      1..max(n - 1, 1)
      |> Enum.map(fn _ -> :rand.uniform(max(size, 1)) end)
      |> Enum.uniq()
      |> Enum.sort()

    {chunks, last} =
      Enum.map_reduce(cuts, 0, fn cut, from ->
        {binary_part(text, from, cut - from), cut}
      end)

    chunks ++ [binary_part(text, last, size - last)]
  end

  describe "the D75 adversarial exemplar — an inline ``` inside a fence body" do
    # The old law counted 3 substring matches over the whole prefix, so it saw an
    # ODD count at the first "\n\n" and… committed at byte 13 anyway on the
    # NEXT boundary, then rewrote it. The honest floor is 0 while the fence is
    # still open.
    @exemplar "Here:\n\n```go\nfmt.Println(\"```\")\n\nmore prose\n"

    test "no boundary is committed while the fence is still open" do
      state = stream(@exemplar)

      # Byte 7 (after "Here:\n\n") is the only boundary outside the fence; the
      # blank line INSIDE the go fence is not one.
      assert state.stable_len == 7
      assert state.stable_html == "Here:\n\n"
      assert StreamTail.tail(state) == "```go\nfmt.Println(\"```\")\n\nmore prose\n"
    end

    test "the inline ``` does not fabricate a skeleton once the fence closes" do
      state = stream(@exemplar <> "```\n")
      assert {:text, _} = StreamTail.classify(state)
      # …and the closed fence releases the boundary on the next blank line.
      assert stream(@exemplar <> "```\n\n").stable_len == byte_size(@exemplar) + 5
    end

    test "an inline ``` in PLAIN prose never pins the boundary (the live prod defect)" do
      # One stray inline fence used to make `balanced_fences?` odd for EVERY
      # candidate — boundary 0 for the whole remaining turn.
      deltas = ["Use the ``` marker.\n\n", "Then this.\n\n", "And this.\n\n"]
      state = stream(deltas)

      assert state.stable_len == byte_size(Enum.join(deltas))
      assert StreamTail.tail(state) == ""
      assert {:text, ""} = StreamTail.classify(state)
    end
  end

  describe "tilde fences" do
    test "a blank line inside a ~~~ fence is not a boundary" do
      text = "intro\n\n~~~\nline one\n\nline two\n"
      state = stream(text)

      assert state.stable_len == 7
      assert {:component, "code", "" <> _} = StreamTail.classify(state)
    end

    test "a ~~~ fence closes on ~~~ and releases the boundary" do
      text = "intro\n\n~~~\nbody\n\nmore\n~~~\n\n"
      assert boundary(text) == byte_size(text)
    end

    test "a backtick line does NOT close a tilde fence" do
      text = "~~~\nbody\n```\n\nstill inside\n"
      assert boundary(text) == 0
    end
  end

  describe "indent" do
    test "4-space-indented backticks are code CONTENT, not a fence" do
      # The old law froze the boundary at 0 forever here (odd substring count).
      text = "intro\n\n    ```\n    indented code\n\ntrailing prose\n"
      assert boundary(text) == byte_size("intro\n\n    ```\n    indented code\n\n")
    end

    test "3-space-indented backticks ARE a fence" do
      text = "intro\n\n   ```\nbody\n\nstill inside\n"
      assert boundary(text) == 7
    end
  end

  describe "run length" do
    test "an inner 3-backtick line does not close a 4-backtick fence" do
      # mdlite.go:107 advances to 32 of 50 — INSIDE the open fence.
      text = "````\nlorem\n```\n\nipsum\n"
      assert boundary(text) == 0

      closed = text <> "````\n\n"
      assert boundary(closed) == byte_size(closed)
    end

    test "a longer closing run closes a shorter fence" do
      text = "```\nbody\n`````\n\nafter\n"
      # The boundary is the blank line AFTER the close — "after\n" has no blank
      # line beneath it yet, so it is still the forming tail.
      assert boundary(text) == byte_size("```\nbody\n`````\n\n")
    end

    test "a closing line with trailing non-whitespace does not close" do
      text = "```\nbody\n``` not a close\n\nafter\n"
      assert boundary(text) == 0
    end

    test "a closing line with trailing whitespace DOES close" do
      text = "```\nbody\n```   \n\nafter\n"
      assert boundary(text) == byte_size("```\nbody\n```   \n\n")
    end

    test "an opening backtick fence's info string may not contain a backtick" do
      # ```a```b at line start is inline code in a paragraph, not a fence.
      text = "```a```b\n\nafter\n"
      assert boundary(text) == byte_size("```a```b\n\n")
    end
  end

  describe "CRLF on the carry" do
    test "a CRLF stream commits its boundaries" do
      # The old law matched "\n\n" literally and never saw one → boundary 0.
      text = "alpha\r\n\r\nbeta\r\n\r\n"
      state = stream(text)

      assert state.text == "alpha\n\nbeta\n\n"
      assert state.stable_len == byte_size("alpha\n\nbeta\n\n")
    end

    test "a delta that splits between \\r and \\n still yields one boundary" do
      whole = stream("alpha\r\n\r\nbeta\r\n\r\n")
      split = stream(["alpha\r", "\n\r", "\nbeta\r\n\r\n"])

      assert split.text == whole.text
      assert split.stable_len == whole.stable_len
    end

    test "a lone CR is preserved, not swallowed" do
      state = stream(["carriage\r", "return\n\n"])
      assert state.text == "carriage\rreturn\n\n"
    end

    test "CRLF inside a fence keeps the fence law working" do
      text = "```go\r\nbody\r\n\r\nstill inside\r\n"
      assert boundary(text) == 0
      assert boundary(text <> "```\r\n\r\n") == byte_size("```go\nbody\n\nstill inside\n```\n\n")
    end
  end

  describe "chunking invariance (chat-TUI D75's core test law)" do
    @fixtures [
      {"inline fence exemplar",
       "Here:\n\n```go\nfmt.Println(\"```\")\n\nmore prose\n```\n\ndone\n"},
      {"tilde fence", "intro\n\n~~~\nbody\n\nmore\n~~~\n\ntail\n"},
      {"indented code", "intro\n\n    ```\n    code\n\nprose\n"},
      {"four backticks", "````\nlorem\n```\n\nipsum\n````\n\nafter\n"},
      {"crlf", "alpha\r\n\r\n```md\r\nbody\r\n\r\n```\r\n\r\nomega\r\n"},
      {"forming table", "lead in\n\n| a | b |\n| - | - |\n"},
      {"prose only", "one\n\ntwo\n\nthree\n\n"},
      # mob-bl-streamtail-blank-line-law: a provider that pads its paragraph
      # break with spaces/tabs still emits a paragraph break. Under the old
      # strictly-byte-empty comparison this text had NO boundary at all, so the
      # invariance held vacuously (every partition agreed on 0).
      {"whitespace-padded blank lines",
       "alpha\n   \nbeta\n\t\ngamma\n \t \n```go\nx()\n   \ny()\n```\n \nomega\n"}
    ]

    for {label, text} <- @fixtures do
      test "#{label}: 24 random partitions all reach the identical quiescent state" do
        text = unquote(text)
        whole = stream(text)

        for seed <- 1..24 do
          chunks = partition(text, 2 + rem(seed, 9), seed)
          assert Enum.join(chunks) == text
          partitioned = stream(chunks)

          assert partitioned == whole,
                 "partition #{seed} (#{inspect(chunks)}) diverged from the whole-text scan"
        end
      end
    end

    # ── the blank-line law itself (mob-bl-streamtail-blank-line-law) ──────
    #
    # Invariance alone cannot catch this clause: under the old `line == ""` the
    # whitespace-padded fixture simply had no boundary anywhere, and every
    # partition agreed on 0. These assert the VALUE, so reverting the fold to
    # the strict comparison reds them (boundary drops to 0 / to the earlier
    # byte-empty line) instead of passing vacuously.
    test "a whitespace-only line commits a boundary, like every other blank line" do
      # "alpha\n" is bytes 0..5, "   \n" is 6..9 — the boundary is the byte
      # after that line's newline, exactly where "beta" starts.
      assert boundary("alpha\n   \nbeta") == 10
      assert boundary("alpha\n\t\nbeta") == 8
      assert boundary("alpha\n \t \nbeta") == 10

      # and the byte-empty line still behaves as it always did.
      assert boundary("alpha\n\nbeta") == 7
    end

    test "a whitespace-only line inside a fence is still NOT a boundary" do
      # The fence clause is untouched: only the no-fence clause changed. The
      # last boundary is the blank line ABOVE the fence, never a padded line
      # inside its body.
      text = "intro\n   \n```go\nbody\n   \nmore\n"
      assert boundary(text) == 10
    end

    test "byte-at-a-time streaming is identical to one whole delta" do
      text = "Here:\n\n```go\nfmt.Println(\"```\")\n\nmore\n```\n\nend\n"
      bytes = for <<b <- text>>, do: <<b>>

      assert stream(bytes) == stream(text)
    end
  end

  describe "classify — the four mis-fires the substring counter produced" do
    test "an unpaired inline ``` plus a REAL open fence still yields a skeleton" do
      # Substring count: 1 (inline) + 1 (fence) = 2, EVEN → the old law showed
      # no skeleton at all and streamed the raw fence source as prose.
      state = stream("Use ``` alone.\n\n```mermaid\ngraph TD;\n")

      assert {:component, "diagram", prose} = StreamTail.classify(state)
      assert prose == ""
      assert state.stable_len == byte_size("Use ``` alone.\n\n")
    end

    test "a fence-less tail never fabricates a skeleton" do
      # One stray inline ``` = odd count → the old law invented a "code"
      # skeleton and hid the whole answer behind it.
      state = stream("intro\n\nThe ``` marker is prose here")

      assert {:text, "The ``` marker is prose here"} = StreamTail.classify(state)
    end

    test "a forming ~~~ fence is classified as a component" do
      state = stream("intro\n\n~~~python\nprint(1)")
      assert {:component, "code", ""} = StreamTail.classify(state)
    end

    test "4-space-indented backticks are not a forming component" do
      state = stream("intro\n\n    ```\n    indented")
      assert {:text, "    ```\n    indented"} = StreamTail.classify(state)
    end

    test "prose above an open fence keeps streaming" do
      state = stream("Some words first.\nAnd more.\n```go\nx := 1")

      assert {:component, "code", "Some words first.\nAnd more.\n"} = StreamTail.classify(state)
    end

    test "the portabledoc kind is sniffed from the partial JSON" do
      state = stream("```portabledoc\n[{\"type\":\"chart\",")
      assert {:component, "chart", ""} = StreamTail.classify(state)

      state = stream("```portabledoc\n[{\"type\":\"stats\",")
      assert {:component, "stats", ""} = StreamTail.classify(state)

      state = stream("```portabledoc\n[{\"type\":\"whatever\",")
      assert {:component, "block", ""} = StreamTail.classify(state)
    end
  end

  describe "classify — a forming component splits at its FIRST triggering line" do
    test "prose above a forming callout still streams" do
      # The web arm passed prose_before == "" unconditionally: visible_bytes=0,
      # hidden_bytes=43.
      state = stream("Here is the summary:\n> a quoted line\n> and more")

      assert {:component, "callout", "Here is the summary:\n"} = StreamTail.classify(state)
    end

    test "prose above a forming table still streams" do
      state = stream("Results below:\n| col | col |\n| --- | --- |")

      assert {:component, "table", "Results below:\n"} = StreamTail.classify(state)
    end

    test "a component triggered on the still-incomplete first line is caught immediately" do
      state = stream("Results below:\n|")
      assert {:component, "table", "Results below:\n"} = StreamTail.classify(state)
    end

    test "a | line inside a closed fence never triggers the table arm" do
      state = stream("intro\n\n```\n| not a table |\n```\nafter")
      assert {:text, "```\n| not a table |\n```\nafter"} = StreamTail.classify(state)
    end

    test "the table arm is retired once its block commits" do
      state = stream("lead\n| a |\n| - |\n\nplain prose")
      assert {:text, "plain prose"} = StreamTail.classify(state)
    end
  end

  describe "the display cap (charter D131)" do
    setup do
      prev = Application.get_env(:barkpark, :claude_chat, [])

      Application.put_env(
        :barkpark,
        :claude_chat,
        Keyword.put(prev, :max_streaming_display_bytes, 1024)
      )

      on_exit(fn -> Application.put_env(:barkpark, :claude_chat, prev) end)
    end

    test "a flood freezes at the last stable boundary and is terminal" do
      chunk = String.duplicate("a", 48) <> "\n\n"
      state = stream(List.duplicate(chunk, 60))

      assert state.capped == true
      assert byte_size(state.text) <= 1024 + byte_size(chunk)
      assert StreamTail.tail(state) == ""

      frozen = byte_size(state.text)
      after_more = stream(List.duplicate(chunk, 60) ++ List.duplicate(chunk, 60))
      assert byte_size(after_more.text) == frozen
    end

    test "one giant unbroken block freezes with NO committed prefix" do
      state = stream(String.duplicate("x", 2048))

      assert state.capped == true
      assert state.stable_len == 0
      assert state.text == ""
      assert state.stable_html == nil
    end

    test "a capped state stays COHERENT — classify/1 cannot raise on it" do
      # freeze/2 truncates `text`; if the scan kept pointing past the new end,
      # `classify/1` would `binary_part` out of bounds. The HEEx guards on
      # `capped` today, but an SSE producer resuming a capped holder must not
      # have to.
      capped = stream(["```go\n"] ++ List.duplicate(String.duplicate("x", 64) <> "\n", 40))
      assert capped.capped == true
      assert capped.scan.pos <= byte_size(capped.text)
      assert capped.scan.fence_start == nil
      assert {:text, ""} = StreamTail.classify(capped)

      # …and the same for a state that DID commit a prefix before freezing.
      with_prefix = stream(List.duplicate(String.duplicate("a", 48) <> "\n\n", 60))
      assert with_prefix.capped == true
      assert with_prefix.scan.pos == byte_size(with_prefix.text)
      assert {:text, ""} = StreamTail.classify(with_prefix)
    end

    test "the state stays a BARE MAP so the HEEx Access brackets work" do
      state = stream("hello\n\n")

      assert is_map(state)
      refute is_struct(state)
      assert state[:capped] == false
    end
  end

  describe "incrementality" do
    # PREREQUISITE, not an optimization: a naive full rescan of this shape
    # measured 10.7 SECONDS per delta (each blank-line candidate re-splits the
    # whole prefix). The fold touches every line exactly once, ever.
    test "a 12 KB unterminated fence costs microseconds per delta" do
      deltas = ["```go\n"] ++ List.duplicate("blah blah blah\n\n", 800)
      total = IO.iodata_length(deltas)
      assert total > 12_000

      {micros, state} = :timer.tc(fn -> stream(deltas) end)

      assert state.stable_len == 0
      # 801 deltas over 12 KB: the fold is linear. A full rescan of this exact
      # shape took 10.7 s — three orders of magnitude outside this bound.
      assert micros < 1_000_000,
             "12 KB unterminated fence took #{micros}µs for #{length(deltas)} deltas"
    end
  end

  describe "skeleton_label/1" do
    test "the vocabulary is exactly the seven server labels (charter D67)" do
      for label <- ~w(diagram chart stats table callout code) do
        assert StreamTail.skeleton_label(label) == label
      end

      assert StreamTail.skeleton_label("anything-else") == "block"
    end
  end
end
