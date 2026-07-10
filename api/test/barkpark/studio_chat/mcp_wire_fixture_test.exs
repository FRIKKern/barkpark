defmodule Barkpark.StudioChat.McpWireFixtureTest do
  @moduledoc """
  ALWAYS-ON shape tests over the committed MCP loopback wire fixtures —
  the wave-12 ground truth for charter D64 (loopback wire shapes) and D65
  (bare `-p` denies the first MCP tool_use).

  FIXTURE PROVENANCE (charter D62). Both fixtures were captured on
  claude 2.1.206 (Claude Code) on 2026-07-10 by spawning the real binary with
  `--mcp-config <file> --strict-mcp-config` pointing at `bp mcp serve --tools
  tasks`, forcing exactly one `mcp__barkpark__task_ready` call (`--model haiku
  --max-budget-usd 0.30`, cost law D56):

    * `mcp_tool_success.ndjson` — `--allowedTools mcp__barkpark__task_ready`
      granted the call: init frame with `mcp_servers` CONNECTED (and ONLY our
      server — strict), the `mcp__barkpark__task_ready` tool_use, and the
      SUCCESS tool_result: a list with ONE `{"type":"text"}` block whose `text`
      is a JSON-ENCODED STRING decoding to `{"ok":true,"docs":[...]}` (D64).
    * `mcp_permission_denied.ndjson` — same spawn WITHOUT `--allowedTools`:
      bare `-p` denies the first MCP tool_use (D65). The tool_result carries
      `is_error: true` and its content is a PLAIN STRING (never a block list);
      the terminal result frame names the denial in `permission_denials`.

  Sanitization (stated in each fixture's own first-line provenance header):
  the success payload's live guerrilla task was replaced with a neutral doc —
  the envelope (`{"ok":true,"docs":[...]}`), the JSON-string transport, and
  every kept frame envelope are VERBATIM wire bytes. Hook/thinking_tokens/
  rate_limit/ToolSearch frames were dropped and thinking blocks stripped:
  these fixtures document the MCP wire contract, not the host's tool roster.

  Wave-12 S5 (native chips) dispatches on OUR tool name prefix
  (`mcp__barkpark__`, the deliberate narrow D38 exception) and Jason-decodes
  the text payload — the shapes pinned here are exactly what it builds against.
  """
  use ExUnit.Case, async: true

  @fixtures_dir Path.expand("../../fixtures/claude_chat", __DIR__)

  @curated_six ~w(task_ready task_next task_show task_close task_create task_prime)

  # Line 1 of each mcp_*.ndjson is a `fixture_provenance` header (D62: source
  # command, capture date, binary version, sanitization statement); the frames
  # follow. Fold-style consumers dispatching on `subtype` ignore it by design.
  defp load(name) do
    [prov | frames] =
      @fixtures_dir
      |> Path.join(name)
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)

    assert prov["type"] == "fixture_provenance",
           "#{name} must open with a fixture_provenance header (charter D62)"

    {prov, frames}
  end

  defp init_frame(frames),
    do: Enum.find(frames, &(&1["type"] == "system" and &1["subtype"] == "init"))

  defp mcp_tool_use(frames) do
    frames
    |> Enum.filter(&(&1["type"] == "assistant"))
    |> Enum.flat_map(&get_in(&1, ["message", "content"]))
    |> Enum.find(fn b ->
      b["type"] == "tool_use" and String.starts_with?(b["name"] || "", "mcp__barkpark__")
    end)
  end

  defp tool_result(frames) do
    frames
    |> Enum.filter(&(&1["type"] == "user"))
    |> Enum.flat_map(&get_in(&1, ["message", "content"]))
    |> Enum.find(&(is_map(&1) and &1["type"] == "tool_result"))
  end

  describe "provenance headers (charter D62)" do
    for fixture <- ["mcp_tool_success.ndjson", "mcp_permission_denied.ndjson"] do
      test "#{fixture} carries binary version, date, source command, sanitization" do
        {prov, _} = load(unquote(fixture))

        assert prov["captured_with"] =~ "2.1.206",
               "fixture not stamped with the pinned capture binary (D67 pin is 2.1.206)"

        assert is_binary(prov["captured_at"]) and prov["captured_at"] != ""
        assert prov["source_command"] =~ "--mcp-config"
        assert prov["source_command"] =~ "--strict-mcp-config"
        assert prov["mcp_server_command"] =~ "bp mcp serve"
        assert is_binary(prov["sanitized"]) and prov["sanitized"] != ""
      end
    end
  end

  describe "init frame — mcp_servers connected (charter D64)" do
    for fixture <- ["mcp_tool_success.ndjson", "mcp_permission_denied.ndjson"] do
      test "#{fixture}: barkpark is connected and is the ONLY server (strict)" do
        {_, frames} = load(unquote(fixture))
        init = init_frame(frames)

        assert init, "no system/init frame in the fixture"

        # --strict-mcp-config: exactly our server, connected — a "failed" status
        # here is the falsification the loopback spawn must surface, not hide.
        assert init["mcp_servers"] == [%{"name" => "barkpark", "status" => "connected"}]

        # The curated six ride the advertised tool list under our namespace.
        tools = init["tools"] || []

        for t <- @curated_six do
          assert "mcp__barkpark__#{t}" in tools,
                 "init does not advertise mcp__barkpark__#{t}"
        end
      end
    end
  end

  describe "success wire shape (charter D64)" do
    test "the mcp tool_use carries our namespaced name and a schema-shaped input" do
      {_, frames} = load("mcp_tool_success.ndjson")
      tu = mcp_tool_use(frames)

      assert tu, "no mcp__barkpark__* tool_use frame in the success fixture"
      assert tu["name"] == "mcp__barkpark__task_ready"
      assert is_binary(tu["id"]) and tu["id"] != ""
      assert tu["input"] == %{"limit" => 1}
    end

    test "the tool_result is ONE text block whose text is a JSON-encoded string" do
      {_, frames} = load("mcp_tool_success.ndjson")
      tu = mcp_tool_use(frames)
      tr = tool_result(frames)

      assert tr, "no tool_result frame in the success fixture"
      # The result answers OUR tool_use — id-linked, not positional.
      assert tr["tool_use_id"] == tu["id"]
      refute tr["is_error"] == true

      # D64 wire law: content is a LIST with exactly one {"type":"text"} block…
      assert [%{"type" => "text", "text" => text}] = tr["content"]
      assert is_binary(text)

      # …whose text is a JSON-ENCODED STRING (double-encoded transport). The
      # chip parser Jason.decodes it; a future binary switching to structured
      # content blocks would fail exactly here.
      assert {:ok, %{"ok" => true, "docs" => [doc | _]}} = Jason.decode(text)

      # Chip-relevant keys survive the round-trip (deep-linkable identity).
      assert is_binary(doc["doc_id"])
      assert is_binary(doc["title"])
    end

    test "the turn ends in a non-error result frame with no permission denials" do
      {_, frames} = load("mcp_tool_success.ndjson")
      result = Enum.find(frames, &(&1["type"] == "result"))

      assert result["subtype"] == "success"
      refute result["is_error"] == true
      assert result["permission_denials"] == []
    end
  end

  describe "permission denial wire shape (charter D65)" do
    test "the denied tool_result is is_error:true with a PLAIN STRING content" do
      {_, frames} = load("mcp_permission_denied.ndjson")
      tu = mcp_tool_use(frames)
      tr = tool_result(frames)

      assert tr, "no tool_result frame in the denial fixture"
      assert tr["tool_use_id"] == tu["id"]
      assert tr["is_error"] == true

      # The denial payload is a bare string — NOT a block list. A consumer
      # assuming the success shape ([%{"type" => "text"}]) would crash here.
      assert is_binary(tr["content"])
      assert tr["content"] =~ "haven't granted"
    end

    test "the terminal result frame names the denial (bare -p denies first MCP use)" do
      {_, frames} = load("mcp_permission_denied.ndjson")
      result = Enum.find(frames, &(&1["type"] == "result"))

      assert [denial] = result["permission_denials"]
      assert denial["tool_name"] == "mcp__barkpark__task_ready"
      assert denial["tool_input"] == %{"limit" => 1}

      # The SESSION still terminates success — the denial is a tool-level
      # outcome, not a run failure. Honest-state law: never conflate the two.
      assert result["subtype"] == "success"
      refute result["is_error"] == true
    end
  end

  describe "sanitization law (charter D62)" do
    test "no live guerrilla task content leaked into the committed success payload" do
      {_, frames} = load("mcp_tool_success.ndjson")
      [%{"text" => text}] = tool_result(frames)["content"]
      {:ok, %{"docs" => docs}} = Jason.decode(text)

      assert Enum.all?(docs, &(&1["labels"] == ["sanitized"])),
             "success fixture carries non-sanitized doc content"
    end
  end
end
