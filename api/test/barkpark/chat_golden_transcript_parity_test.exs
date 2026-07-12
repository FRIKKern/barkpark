defmodule Barkpark.ChatGoldenTranscriptParityTest do
  @moduledoc """
  Cross-surface **chat golden-transcript** parity lock (charter D8 + D13,
  Mechanism A) — the Elixir leg.

  REPLY-BODY-ONLY scope (charter D13): this harness covers ONLY the SETTLED
  assistant reply body — the markdown a model emits, converted to PortableDoc
  blocks by `Barkpark.PortableDoc.FromMarkdown.blocks/1` and rendered as a
  document. Tool / todo / approval / thinking rows are bespoke HEEx
  (`chat_tool_renderer.ex`) with no pdrender twin; their TUI renderers + parity
  mechanism are the named backlog slice `ct-bl-toolrow-renderers`, NOT silently
  covered by the phrase "golden transcript".

  ONE fixture (`GenGoldenTranscript.build/0` itself, three reply variants)
  written to two byte-equal mirrors, asserted here as:

    * the **freshness lock** — the committed api mirror equals a fresh `build/0`
      and the two mirrors decode term-identical (a `FromMarkdown.blocks/1` change
      shipped without regenerating reds HERE, not silently on the TUI);
    * the **block round-trip** — per variant, `FromMarkdown.blocks(markdown)`
      equals the committed `blocks` (the shared JSON both surfaces consume — D8,
      no projection layer on the render path);
    * the **projection floor** — three variants, every required block type
      present (h1/h2/h3 + paragraph + list + table + code + diagram + callout +
      stats), so a gutted regen reds here.

  The Go leg — `pdrender.Decode` → `RenderDoc` realizes the same projection with
  zero `unknown block:` fallback — lives in
  `internal/pdrender/chat_golden_parity_test.go`; it reads the SAME mirror.

  Regenerate with `mix barkpark.chat.gen_golden_transcript` whenever the
  freshness lock reds.
  """
  use ExUnit.Case, async: true

  alias Barkpark.PortableDoc.FromMarkdown
  alias Mix.Tasks.Barkpark.Chat.GenGoldenTranscript

  @api_path Path.expand("../support/fixtures/chat_golden_transcript.json", __DIR__)
  @go_path Path.expand(
             "../../../internal/pdrender/testdata/chat_golden_transcript.json",
             __DIR__
           )

  defp decode!(path), do: path |> File.read!() |> Jason.decode!()

  defp fixture, do: decode!(@api_path)
  defp variants, do: fixture()["variants"]

  # ── freshness lock ──────────────────────────────────────────────────────────

  describe "fixture freshness lock" do
    test "committed api mirror equals a fresh regeneration (build/0)" do
      assert decode!(@api_path) == GenGoldenTranscript.build(),
             "chat_golden_transcript.json is stale — run " <>
               "`mix barkpark.chat.gen_golden_transcript` and re-verify both surfaces."
    end

    test "the two mirrors decode term-identical" do
      assert decode!(@api_path) == decode!(@go_path),
             "the Go mirror drifted — run `mix barkpark.chat.gen_golden_transcript`."
    end

    test "the mirror paths the generator writes match the paths this test reads" do
      assert GenGoldenTranscript.mirror_paths() == [@api_path, @go_path]
    end
  end

  # ── the block round-trip (the shared JSON is FromMarkdown itself) ────────────

  describe "block round-trip (FromMarkdown.blocks/1)" do
    test "every variant's committed blocks equal a fresh FromMarkdown.blocks(markdown)" do
      for v <- variants() do
        assert FromMarkdown.blocks(v["markdown"]) == v["blocks"],
               "variant #{inspect(v["name"])}: committed blocks drifted from " <>
                 "FromMarkdown.blocks/1 — regenerate the fixture."
      end
    end

    test "each projection entry mirrors its block's type sequence one-to-one" do
      for v <- variants() do
        block_types = Enum.map(v["blocks"], & &1["type"])
        proj_types = Enum.map(v["projection"], & &1["type"])

        assert block_types == proj_types,
               "variant #{inspect(v["name"])}: projection type sequence diverged from blocks."
      end
    end
  end

  # ── the projection floor (a gutted regen reds here) ─────────────────────────

  describe "projection coverage floor" do
    test "the fixture is scoped reply-body-only and names the toolrow backlog slice" do
      f = fixture()
      assert f["scope"] == "assistant-reply-body-only"

      assert f["_comment"] =~ "ct-bl-toolrow-renderers",
             "the reply-body-only scope boundary (D13) must be stated in the fixture comment."
    end

    test "there are at least three reply variants" do
      assert length(variants()) >= 3
    end

    test "the required block types are all present across the variants" do
      types =
        variants()
        |> Enum.flat_map(& &1["projection"])
        |> Enum.map(& &1["type"])
        |> MapSet.new()

      required = ~w(heading paragraph list table code diagram callout stats)

      for t <- required do
        assert MapSet.member?(types, t),
               "block type #{inspect(t)} is missing — regen dropped coverage."
      end
    end

    test "all three heading levels (h1/h2/h3) are present" do
      levels =
        variants()
        |> Enum.flat_map(& &1["projection"])
        |> Enum.filter(&(&1["type"] == "heading"))
        |> Enum.map(& &1["level"])
        |> MapSet.new()

      assert MapSet.subset?(MapSet.new([1, 2, 3]), levels),
             "heading levels present: #{inspect(MapSet.to_list(levels))} — need 1, 2 and 3."
    end

    test "every projection entry carries non-empty key text" do
      for v <- variants(), entry <- v["projection"] do
        assert is_binary(entry["text"]) and entry["text"] != "",
               "variant #{inspect(v["name"])} #{inspect(entry["type"])}: empty projection text."
      end
    end
  end
end
