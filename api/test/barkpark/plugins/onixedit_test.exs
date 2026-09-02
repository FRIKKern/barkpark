defmodule Barkpark.Plugins.OnixEditTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.Document
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Plugins.OnixEdit

  describe "manifest/0" do
    test "returns the validated plugin.json map" do
      manifest = OnixEdit.manifest()

      assert is_map(manifest)
      assert manifest["plugin_name"] == "onixedit"
      assert manifest["module"] == "Barkpark.Plugins.OnixEdit"
      assert manifest["version"] =~ ~r/^\d+\.\d+\.\d+/
      assert is_list(manifest["capabilities"])
      assert "schemas" in manifest["capabilities"]
      assert "codelists" in manifest["capabilities"]
    end

    test "manifest declares the book schema file" do
      [book | _] = OnixEdit.manifest()["schemas"]

      assert book["name"] == "book"
      assert book["file"] == "schemas/book.json"
    end
  end

  describe "plugin_name/0 (D20 discriminator)" do
    test "is the literal string 'onixedit'" do
      assert OnixEdit.plugin_name() == "onixedit"
    end
  end

  describe "book_schema!/0" do
    setup do
      {:ok, parsed: OnixEdit.book_schema!()}
    end

    test "parses through SchemaDefinition.parse/2 as v2", %{parsed: parsed} do
      assert %SchemaDefinition.Parsed{} = parsed
      assert parsed.name == "book"
      assert parsed.version == 2
      refute SchemaDefinition.flat?(parsed)
    end

    test "exposes a deeply nested ONIX product surface", %{parsed: parsed} do
      # Spot-check that key top-level fields land — the schema is a contract
      # WI2 / WI3 / WI4 read.
      top_names = Enum.map(parsed.fields, & &1.name)

      for required <- ~w(
            productIdentifiers productForm titleDetails contributors
            languages subjects themaSubjectCategory audienceCodes
            collateralDetail publishingDetail relatedMaterial productSupplies
          ) do
        assert required in top_names, "expected `#{required}` at top level of book schema"
      end
    end

    test "field count meets the 'large book schema' bar", %{parsed: parsed} do
      assert count_fields(parsed.fields) >= 150,
             "book schema should declare at least 150 nested fields; got #{count_fields(parsed.fields)}"
    end

    test "carries onix: metadata on at least some fields (Phase 6 export hook)", %{parsed: parsed} do
      assert Enum.any?(walk_fields(parsed.fields), fn f -> is_map(f.onix) end)
    end

    test "uses bp_* prefix for plugin custom fields", %{parsed: parsed} do
      bp = Enum.filter(parsed.fields, &String.starts_with?(&1.name, "bp_"))
      assert bp != []
    end
  end

  describe "WI2 hand-off surface" do
    setup do
      {:ok, parsed: OnixEdit.book_schema!()}
    end

    test "contributors is an arrayOf composite (WI2 fills inner shape)", %{parsed: parsed} do
      contributors = find_top(parsed, "contributors")

      assert contributors.type == "arrayOf"
      assert contributors.ordered == true

      of = contributors.of

      assert match?(%SchemaDefinition.Field{type: "composite"}, of),
             "contributors `of` should be a composite for WI2 to enrich, got #{inspect(of)}"
    end

    test "themaSubjectCategory is an arrayOf codelist pinned to ONIX list 93", %{parsed: parsed} do
      thema = find_top(parsed, "themaSubjectCategory")

      assert thema.type == "arrayOf"
      assert thema.ordered == false

      assert %SchemaDefinition.Field{
               type: "codelist",
               codelist_id: "onixedit:thema"
             } = thema.of

      assert thema.of.onix["codelistId"] == 93
    end

    test "collateralDetail.textContents is the localizedText insertion point", %{parsed: parsed} do
      collateral = find_top(parsed, "collateralDetail")
      assert collateral.type == "composite"

      text_contents = Enum.find(collateral.fields, &(&1.name == "textContents"))
      assert text_contents != nil, "expected `textContents` under collateralDetail"

      assert text_contents.type == "arrayOf",
             "WI2 will swap or extend the inner composite with a localizedText blurb"
    end
  end

  describe "codelist_requirements/0" do
    test "ContributorRole codelist 17 is declared (D17)" do
      reqs = OnixEdit.codelist_requirements()

      assert Enum.any?(reqs, fn r ->
               r.list_id == "onixedit:contributor_role" and r.issue == "17"
             end),
             "ContributorRole list 17 must be in the codelist requirements (D17)"
    end

    test "Thema is declared at the issue boot actually seeds, not at ONIX list 93" do
      reqs = OnixEdit.codelist_requirements()
      thema = Enum.find(reqs, &(&1.list_id == "onixedit:thema"))

      # The declaration must track `seed_thema/1`'s pinned constant. It used
      # to say "93", which is the ONIX list NUMBER for "Supplier role" —
      # EDItEUR publishes Thema separately, with its own version.
      assert thema.issue == Barkpark.Codelists.EDItEUR.thema_issue()
      assert thema.issue == "1.6"

      refute thema.issue == "93",
             "ONIX list 93 is Supplier role; the 93 beside Thema in book.json " <>
               "is a SubjectSchemeIdentifier value inside list 27"
    end

    test "all requirements are scoped to the onixedit plugin (D20)" do
      reqs = OnixEdit.codelist_requirements()
      assert Enum.all?(reqs, &(&1.plugin_name == "onixedit"))
    end
  end

  describe "Barkpark.Plugin contract" do
    test "register_schemas/1 returns at least the book SchemaDefinition" do
      [book | _] = OnixEdit.register_schemas([])

      assert %SchemaDefinition{name: "book"} = book
      assert book.visibility == "private"
    end

    test "default behaviour callbacks return their no-op shapes" do
      # register_routes/1 was a no-op until G2.s4 — OnixEdit now overrides it
      # with 4 routes (ping pilot, bokbasen + staleness LVs, export controller).
      # See the dedicated "register_routes/1 contributes …" assertion below.
      assert OnixEdit.validate_settings(%{}) == :ok
      assert OnixEdit.checkers() == []
    end

    test "register_routes/1 contributes ping + bokbasen + staleness + export" do
      routes = OnixEdit.register_routes(%{})
      assert length(routes) == 4
      paths = Enum.map(routes, fn route -> elem(route, 1) end)
      assert "/onixedit/ping" in paths
      assert "/onixedit/bokbasen" in paths
      assert "/onixedit/staleness" in paths
      assert "/onixedit/export/:dataset/:id" in paths
    end

    test "register_workers/1 contributes the Bokbasen.Auth token cache and the dataset-host boot check" do
      # Goal barkpark-G1, task s2: OnixEdit overrides the no-op default and
      # asks the host to start its OAuth2 token cache as part of the boot
      # supervision tree. The previous hardcode in Barkpark.Application is
      # gone; this callback is the only way Auth gets started.
      #
      # The SECOND child is the dataset-host boot check. It lives here rather
      # than in Barkpark.Application on purpose: a call from the host's boot
      # path would make a core module depend on a removable plugin and break
      # the fresh-install invariant, and boot_collectors.ex rescues around the
      # host's own boot work, so a raise there would be swallowed instead of
      # failing closed. A plugin child spec is the only path that both escapes
      # that rescue and disappears entirely when OnixEdit is disabled.
      #
      # Asserted as a whole list, not `in`: this callback IS the boot
      # supervision contract, so a third child appearing unannounced should
      # red here rather than ride along unnoticed.
      assert OnixEdit.register_workers(%{phase: :boot}) ==
               [
                 Barkpark.Plugins.OnixEdit.Bokbasen.Auth,
                 %{
                   id: :onixedit_dataset_host_boot_check,
                   start: {Barkpark.Plugins.OnixEdit, :start_dataset_host_check, []},
                   restart: :temporary
                 }
               ]
    end
  end

  describe "resolve_doc_actions/2 (struct-safe hide_publish gate)" do
    @publish_action %{"name" => "publish_to_bokbasen", "label" => "Publish to Bokbasen"}

    # The twin of the github raise: hide_publish_action?/1 ran the identical
    # `get_in(doc, ["content", ...])` ladder, which raises `Document does not
    # implement the Access behaviour` on any real %Document{} book lacking a
    # bp_export_status key. Called DIRECTLY (no Registry rescue) so a regression
    # re-raises into the test.

    test "real %Document{} book WITHOUT bp_export_status keeps the publish action (no raise)" do
      doc = %Document{type: "book", content: %{"title" => "x"}}
      ctx = %{doc_type: "book", doc: doc}

      assert OnixEdit.resolve_doc_actions([@publish_action], ctx) == [@publish_action]
    end

    test "real %Document{} book with default empty content keeps the publish action" do
      ctx = %{doc_type: "book", doc: %Document{type: "book"}}
      assert OnixEdit.resolve_doc_actions([@publish_action], ctx) == [@publish_action]
    end

    test "real %Document{} book with an in-flight export state hides the publish action" do
      doc = %Document{type: "book", content: %{"bp_export_status" => %{"state" => "staging"}}}
      ctx = %{doc_type: "book", doc: doc}

      assert OnixEdit.resolve_doc_actions([@publish_action], ctx) == []
    end

    test "string-keyed plain-map book with in-flight state hides the publish action" do
      ctx = %{
        doc_type: "book",
        doc: %{"content" => %{"bp_export_status" => %{"state" => "polling"}}}
      }

      assert OnixEdit.resolve_doc_actions([@publish_action], ctx) == []
    end

    test "non-book doc is left untouched" do
      ctx = %{doc_type: "post", doc: %Document{type: "post"}}
      assert OnixEdit.resolve_doc_actions([@publish_action], ctx) == [@publish_action]
    end
  end

  # ─── helpers ──────────────────────────────────────────────────────────────

  defp find_top(parsed, name) do
    Enum.find(parsed.fields, &(&1.name == name)) ||
      flunk("missing top-level field `#{name}`")
  end

  defp count_fields(fields) when is_list(fields) do
    Enum.reduce(fields, 0, fn f, acc -> acc + 1 + count_in_field(f) end)
  end

  defp count_in_field(%SchemaDefinition.Field{type: "composite", fields: kids})
       when is_list(kids),
       do: count_fields(kids)

  defp count_in_field(%SchemaDefinition.Field{
         type: "arrayOf",
         of: %SchemaDefinition.Field{} = inner
       }),
       do: 1 + count_in_field(inner)

  defp count_in_field(_), do: 0

  defp walk_fields(fields) when is_list(fields) do
    Enum.flat_map(fields, fn f ->
      [f | walk_in_field(f)]
    end)
  end

  defp walk_in_field(%SchemaDefinition.Field{type: "composite", fields: kids}) when is_list(kids),
    do: walk_fields(kids)

  defp walk_in_field(%SchemaDefinition.Field{
         type: "arrayOf",
         of: %SchemaDefinition.Field{} = inner
       }),
       do: [inner | walk_in_field(inner)]

  defp walk_in_field(_), do: []
end
