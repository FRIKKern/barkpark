defmodule BarkparkWeb.Studio.StudioLive.PathsTest do
  @moduledoc """
  URL-equals-state, layer 1 (bp-studio-deep-link wave 1, slice `sdl-w1-gate`).

  Unit round-trip for the pure Studio URL builders in
  `BarkparkWeb.Studio.StudioLive.Paths` — the choke point every Studio
  link/`push_patch`/`push_navigate` funnels through so a destination has ONE
  canonical spelling. The contract these tests pin: **build → parse → rebuild
  is identity**. If a path a builder emits cannot be parsed back into the
  (dataset, segments, desk) that produced it, deep-linking that URL cannot
  reproduce the scope — the exact bug the epic closes.

  The inverse parser (`parse_studio_path/1`) lives here, in the test: it is the
  independent oracle. The builder and the parser were written from opposite
  ends, so a drift in either turns this red.

  Scope note: this slice PINS the post-fix builder surface — the full
  promoted grammar from sdl-w1-builder (`studio_path_for/3`, `studio_path/4`,
  `scoped_root/3`, `flat_root/1`, `paper_path/2`, `append_desk_query/2`,
  `desk_chip_href/4`, `plugin_link_href/2`).
  """

  use ExUnit.Case, async: true

  alias BarkparkWeb.Studio.StudioLive.Paths

  # ── The inverse oracle ────────────────────────────────────────────────────
  # Parse a builder-emitted Studio path (NO scope prefix) back into the tuple
  # that produced it: {dataset, segments, desk}. Deliberately independent of
  # the builder's implementation — it re-derives the grammar from the URL text.
  defp parse_studio_path(path) when is_binary(path) do
    {base, desk} =
      case String.split(path, "?", parts: 2) do
        [b] -> {b, nil}
        [b, query] -> {b, Map.get(URI.decode_query(query), "desk")}
      end

    segments =
      case base do
        "/d/" <> rest ->
          case String.split(rest, "/studio", parts: 2) do
            [_ds, ""] -> []
            [_ds, "/" <> tail] -> String.split(tail, "/")
            [_ds, tail] when tail != "" -> String.split(tail, "/")
            _ -> :error
          end

        _ ->
          :error
      end

    dataset =
      case base do
        "/d/" <> rest -> rest |> String.split("/studio", parts: 2) |> hd()
        _ -> :error
      end

    {dataset, segments, desk}
  end

  describe "studio_path_for/3 — the /d/:dataset/studio[/...] suffix builder" do
    test "empty segment list yields the dataset root" do
      assert Paths.studio_path_for([], "production", []) == "/d/production/studio"
    end

    test "segments append as /-joined path" do
      assert Paths.studio_path_for(["post", "p1"], "production", []) ==
               "/d/production/studio/post/p1"
    end

    test "desk rides as a ?desk= query" do
      assert Paths.studio_path_for([], "production", desk: "drafts") ==
               "/d/production/studio?desk=drafts"

      assert Paths.studio_path_for(["post"], "production", desk: "drafts") ==
               "/d/production/studio/post?desk=drafts"
    end

    # The property: for every representative shape, build then parse-back
    # recovers EXACTLY the inputs, and rebuilding from the recovered tuple
    # reproduces the original string byte-for-byte.
    test "build → parse → rebuild is identity across representative shapes" do
      cases = [
        {[], "production", nil},
        {["post"], "production", nil},
        {["post", "p1"], "production", nil},
        {["book", "bk1", "chapters", "3"], "production", nil},
        {[], "production", "drafts"},
        {["post", "p1"], "staging", "published"},
        # Hyphenated (URI-safe) dataset slug — the realistic encodable case.
        {["note", "n1"], "content-review", "in-review"}
      ]

      for {segments, dataset, desk} <- cases do
        opts = if desk, do: [desk: desk], else: []
        built = Paths.studio_path_for(segments, dataset, opts)

        parsed_back = parse_studio_path(built)

        assert parsed_back == {dataset, segments, desk},
               "parse-back drifted for #{inspect({segments, dataset, desk})} → #{built}, got #{inspect(parsed_back)}"

        # Rebuild from the recovered tuple → byte-identical to the original.
        {ds2, segs2, desk2} = parse_studio_path(built)
        opts2 = if desk2, do: [desk: desk2], else: []
        assert Paths.studio_path_for(segs2, ds2, opts2) == built
      end
    end
  end

  describe "append_desk_query/2 — desk encoding" do
    test "nil and empty desk are no-ops" do
      assert Paths.append_desk_query("/d/production/studio", []) == "/d/production/studio"
      assert Paths.append_desk_query("/d/production/studio", desk: nil) == "/d/production/studio"
      assert Paths.append_desk_query("/d/production/studio", desk: "") == "/d/production/studio"
    end

    test "a plain desk appends verbatim" do
      assert Paths.append_desk_query("/d/production/studio", desk: "drafts") ==
               "/d/production/studio?desk=drafts"
    end

    test "special chars are www-form encoded and decode back to the original desk" do
      # A desk value carrying URI-significant chars must survive the round-trip
      # through the query string — else a shared deep link lands on the wrong desk.
      for desk <- ["a b", "a&b", "a=b", "drafts/2026", "æøå"] do
        built = Paths.append_desk_query("/d/production/studio", desk: desk)
        [_base, query] = String.split(built, "?", parts: 2)
        assert URI.decode_query(query) == %{"desk" => desk}
      end
    end
  end

  describe "desk_chip_href/4 — scope-prefixed bookmarkable desk href" do
    test "empty prefix yields the bare flat path" do
      assert Paths.desk_chip_href("", [], "production", nil) == "/d/production/studio"

      assert Paths.desk_chip_href("", ["post"], "production", "drafts") ==
               "/d/production/studio/post?desk=drafts"
    end

    test "a scope prefix is prepended to the canonical suffix" do
      assert Paths.desk_chip_href("/w/acme/p/site", ["post"], "production", "drafts") ==
               "/w/acme/p/site/d/production/studio/post?desk=drafts"
    end

    test "build → parse → rebuild is identity (prefix stripped, suffix round-trips)" do
      for {prefix, segments, dataset, desk} <- [
            {"", [], "production", nil},
            {"/w/acme/p/site", ["post", "p1"], "production", "drafts"},
            {"/w/a/p/b", ["book", "bk1"], "staging", nil}
          ] do
        built = Paths.desk_chip_href(prefix, segments, dataset, desk)
        suffix = String.replace_prefix(built, prefix, "")
        assert {^dataset, ^segments, ^desk} = parse_studio_path(suffix)
        # The prefix is recoverable and the whole href re-composes.
        assert prefix <> suffix == built
      end
    end
  end

  describe "plugin_link_href/2 — flat plugin href → /d/ canonical rewrite (at source)" do
    test "empty prefix (flat surface) passes the href through untouched" do
      assert Paths.plugin_link_href("", "/studio/production/onixedit/ping") ==
               "/studio/production/onixedit/ping"
    end

    test "a scope prefix rewrites /studio/<ds>/... to the /d/ canonical" do
      assert Paths.plugin_link_href("/w/acme/p/site", "/studio/production/onixedit/ping") ==
               "/w/acme/p/site/d/production/studio/onixedit/ping"

      # No plugin sub-path — just the dataset root.
      assert Paths.plugin_link_href("/w/acme/p/site", "/studio/production") ==
               "/w/acme/p/site/d/production/studio"
    end

    test "a non-/studio href is left alone" do
      assert Paths.plugin_link_href("/w/acme/p/site", "/papers/hello") == "/papers/hello"
      assert Paths.plugin_link_href("/w/acme/p/site", "/admin/pulse") == "/admin/pulse"
    end

    test "the rewritten href parses back to the same dataset + plugin segments" do
      built = Paths.plugin_link_href("/w/acme/p/site", "/studio/production/onixedit/ping")
      suffix = String.replace_prefix(built, "/w/acme/p/site", "")
      assert {"production", ["onixedit", "ping"], nil} = parse_studio_path(suffix)
    end
  end

  describe "promoted builders (sdl-w1-builder) — studio_path/4, scoped_root/3, flat_root/1, paper_path/2" do
    test "studio_path/4 = scope_prefix + studio_path_for/3, nil prefix means flat" do
      for {prefix, segments, dataset, desk} <- [
            {"", [], "production", nil},
            {nil, ["media"], "production", nil},
            {"/w/acme/p/site", [], "production", nil},
            {"/w/acme/p/site", ["post", "p1"], "staging", "drafts"}
          ] do
        opts = if desk, do: [desk: desk], else: []
        built = Paths.studio_path(prefix, segments, dataset, opts)
        assert built == (prefix || "") <> Paths.studio_path_for(segments, dataset, opts)

        # The suffix round-trips through the inverse oracle.
        suffix = String.replace_prefix(built, prefix || "", "")
        assert {^dataset, ^segments, ^desk} = parse_studio_path(suffix)
      end
    end

    test "scoped_root/3 is the canonical scoped Studio root" do
      assert Paths.scoped_root("acme", "site", "production") ==
               "/w/acme/p/site/d/production/studio"

      # Identity with the composed builder — one grammar, two entry points.
      assert Paths.scoped_root("acme", "site", "production") ==
               Paths.studio_path("/w/acme/p/site", [], "production")
    end

    test "flat_root/1 is the deliberate-flat root (rides the 302 funnel)" do
      assert Paths.flat_root("production") == "/studio/production"
    end

    test "paper_path/2 prefixes the reader URL; nil/empty prefix stays flat" do
      assert Paths.paper_path("", "ai-score") == "/papers/ai-score"
      assert Paths.paper_path(nil, "ai-score") == "/papers/ai-score"
      assert Paths.paper_path("/w/acme/p/site", "ai-score") == "/w/acme/p/site/papers/ai-score"
    end
  end
end
