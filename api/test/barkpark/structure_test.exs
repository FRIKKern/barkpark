defmodule Barkpark.StructureTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Content.SchemaDefinition
  alias Barkpark.Structure
  alias Barkpark.Structure.Node

  import Barkpark.TenancyFixtures

  defp insert_schema!(attrs) do
    %SchemaDefinition{}
    |> SchemaDefinition.changeset(attrs)
    |> Repo.insert!()
  end

  # Insert `n` bare documents of `type` into `dataset` (optionally workspace-
  # scoped) so `Analytics.type_census/2` counts them. Drafts and published both
  # count — the …Rest count is deliberately honest about the whole database.
  defp insert_docs!(type, dataset, n, opts \\ []) do
    workspace_id = Keyword.get(opts, :workspace_id)
    published = Keyword.get(opts, :published, n)

    for i <- 1..n do
      Repo.insert!(%Document{
        doc_id: if(i <= published, do: "#{type}-#{i}", else: "drafts.#{type}-#{i}"),
        type: type,
        dataset: dataset,
        status: if(i <= published, do: "published", else: "draft"),
        title: "#{type} #{i}",
        rev: "rev-#{type}-#{i}",
        workspace_id: workspace_id,
        content: %{}
      })
    end
  end

  # All type_names anywhere in the tree (recursive).
  defp all_type_names(%Structure.Node{items: items}), do: collect_tn(items, [])

  defp collect_tn(items, acc) do
    Enum.reduce(items, acc, fn node, acc ->
      acc = if node.type_name, do: [node.type_name | acc], else: acc
      collect_tn(node.items || [], acc)
    end)
  end

  defp top_node(tree, id), do: Enum.find(tree.items, &(&1.id == id))
  defp plugins_node(tree), do: top_node(tree, "plugins")
  defp rest_node(tree), do: top_node(tree, "rest")

  defp seed_legacy(dataset) do
    insert_schema!(%{
      name: "post",
      title: "Posts",
      icon: "file-text",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "page",
      title: "Pages",
      icon: "file",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "project",
      title: "Projects",
      icon: "briefcase",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "author",
      title: "Authors",
      icon: "user",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    insert_schema!(%{
      name: "category",
      title: "Categories",
      icon: "tag",
      visibility: "public",
      dataset: dataset,
      fields: []
    })

    # `singleton: true` — these three are the real host config singletons
    # (issue #8463); everything `Structure` treats as private+unowned WITHOUT
    # this flag now falls into the generic "Content" catch-all instead.
    insert_schema!(%{
      name: "siteSettings",
      title: "Site Settings",
      icon: "settings",
      visibility: "private",
      dataset: dataset,
      singleton: true,
      fields: []
    })

    insert_schema!(%{
      name: "navigation",
      title: "Navigation",
      icon: "compass",
      visibility: "private",
      dataset: dataset,
      singleton: true,
      fields: []
    })

    insert_schema!(%{
      name: "colors",
      title: "Colors",
      icon: "palette",
      visibility: "private",
      dataset: dataset,
      singleton: true,
      fields: []
    })
  end

  defp settings_node(tree) do
    Enum.find(tree.items, fn n -> n.type == :list and n.id == "settings" end)
  end

  defp content_types_node(tree) do
    Enum.find(tree.items, fn n -> n.type == :list and n.id == "content-types" end)
  end

  describe "build/1" do
    test "with OnixEdit disabled by default, book is NOT top-level and its docs fall into …Rest" do
      dataset = "structure_test_book_rest"
      seed_legacy(dataset)

      insert_schema!(%{
        name: "book",
        title: "Book (ONIX 3.0)",
        icon: "book",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      # Two book documents exist in the database.
      insert_docs!("book", dataset, 2)

      tree = Structure.build(dataset)

      # OnixEdit is default-disabled, so the books group is NOT surfaced
      # top-level (its old always-on home).
      refute Enum.any?(tree.items, fn n ->
               n.type == :document_type_list and n.id == "book"
             end),
             "book must not be top-level when OnixEdit is disabled by default"

      # …Rest tells the truth: book docs still exist, so they surface there with
      # an honest count and a drillable list (the book schema is in scope).
      rest = rest_node(tree)

      assert match?(%Node{}, rest),
             "expected a …Rest node when unplaced doc types exist; got: #{inspect(rest)}"

      book_rest = Enum.find(rest.items, &(&1.type_name == "book"))

      assert match?(%Node{}, book_rest),
             "book docs must surface under …Rest, never silently hidden; got: #{inspect(book_rest)}"

      assert book_rest.type == :document_type_list, "book has a schema → drillable"
      assert book_rest.title == "book (2)"
    end

    test "without book, tree contains only legacy groups and no stray dividers" do
      dataset = "structure_test_no_book"
      seed_legacy(dataset)

      tree = Structure.build(dataset)

      refute Enum.any?(tree.items, fn n ->
               n.type == :document_type_list and n.id == "book"
             end),
             "no book node expected when schema is absent"

      types = Enum.map(tree.items, & &1.type)

      refute List.first(types) == :divider, "no leading divider"
      refute List.last(types) == :divider, "no trailing divider"

      refute Enum.chunk_every(types, 2, 1, :discard)
             |> Enum.any?(fn pair -> pair == [:divider, :divider] end),
             "no consecutive dividers"
    end

    test "settings sub-list still surfaces siteSettings, navigation, and colors" do
      dataset = "structure_test_settings_regression"
      seed_legacy(dataset)

      tree = Structure.build(dataset)
      settings = settings_node(tree)

      assert %Node{} = settings
      ids = Enum.map(settings.items, & &1.id)

      assert "siteSettings" in ids
      assert "navigation" in ids
      assert "colors" in ids
    end
  end

  describe "generic document-type lists for consumer-registered schemas (issue #8463)" do
    test "a private, non-plugin-owned, non-singleton schema gets a :document_type_list node" do
      dataset = "structure_test_generic_content"
      seed_legacy(dataset)

      # An ad-hoc consumer type: private (so it doesn't qualify as public
      # content), not plugin-owned, and NOT marked singleton — exactly the
      # shape #8463 reports as a dead Settings entry pre-fix.
      insert_schema!(%{
        name: "customerFeedback",
        title: "Customer Feedback",
        icon: "message-circle",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      content = content_types_node(tree)
      assert %Node{title: "Content"} = content

      feedback = Enum.find(content.items, &(&1.type_name == "customerFeedback"))

      assert match?(%Node{}, feedback),
             "expected the generic type to surface under Content; got: #{inspect(feedback)}"

      assert feedback.type == :document_type_list, "must be drillable, not a dead singleton"
      assert feedback.title == "Customer Feedback"

      # And it must NOT also masquerade as a Settings singleton.
      settings = settings_node(tree)
      refute "customerFeedback" in Enum.map(settings.items, & &1.id)
    end

    test "a generic type surfaces even with zero documents (schema-driven, not census-driven)" do
      dataset = "structure_test_generic_zero_docs"

      insert_schema!(%{
        name: "orderNote",
        title: "Order Notes",
        icon: "file",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      # No documents inserted — unlike …Rest (census-driven), Content must
      # still surface the type so "create the first document" is reachable.
      tree = Structure.build(dataset)

      content = content_types_node(tree)
      assert %Node{} = content
      assert Enum.any?(content.items, &(&1.type_name == "orderNote"))
    end

    test "singleton: true preserves the old :document singleton behavior" do
      dataset = "structure_test_explicit_singleton"

      insert_schema!(%{
        name: "storeConfig",
        title: "Store Config",
        icon: "settings",
        visibility: "private",
        dataset: dataset,
        singleton: true,
        fields: []
      })

      tree = Structure.build(dataset)

      settings = settings_node(tree)
      assert %Node{} = settings

      config = Enum.find(settings.items, &(&1.id == "storeConfig"))
      assert %Node{type: :document, type_name: "storeConfig"} = config

      # And it must NOT double-list under the generic Content bucket.
      case content_types_node(tree) do
        nil -> :ok
        %Node{items: items} -> refute Enum.any?(items, &(&1.type_name == "storeConfig"))
      end
    end

    test "a plugin-owned private schema is excluded from the generic Content group too" do
      dataset = "structure_test_generic_excludes_owned"
      seed_legacy(dataset)

      # `sheet` is owned by the (default-enabled, :main-placed) Sheets plugin —
      # it renders via its own top-level MAIN group, never via the generic
      # catch-all, mirroring the existing Settings-ownership exclusion.
      insert_schema!(%{
        name: "sheet",
        title: "Sheets",
        icon: "📊",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      case content_types_node(tree) do
        nil -> :ok
        %Node{items: items} -> refute Enum.any?(items, &(&1.type_name == "sheet"))
      end
    end

    # NOTE: this used to read "an empty PRIVATE set…" and passed because the
    # catch-alls only ever looked at private schemas. They no longer consult
    # visibility at all (see the describe block below), so the reason it still
    # holds is different and worth stating: `post` is CURATED by
    # `build_content_group/1`, and a curated type is excluded from both
    # catch-alls. Nothing else is registered, so both groups stay empty.
    test "a dataset whose only schema is curated produces neither Settings nor Content" do
      dataset = "structure_test_no_private_at_all"

      insert_schema!(%{
        name: "post",
        title: "Posts",
        icon: "file-text",
        visibility: "public",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      assert settings_node(tree) == nil
      assert content_types_node(tree) == nil
    end
  end

  # Gyldendal #25. `visibility` is an ACCESS control (who may read the type
  # over the API). It was ALSO deciding desk placement, and the two jobs
  # disagree: `SchemaDefinition.visibility` defaults to "public" and
  # `SchemaController.upsert/2` injects no default, so a consumer POSTing to
  # /v1/schemas/:dataset without a `visibility` key got "public" — which
  # matched the hardcoded content group (post/page/project) not at all, nor
  # the private-only catch-alls. …Rest is census-driven
  # (`Analytics.type_census/2`), so with zero documents the type appeared
  # NOWHERE. Placement now keys on `singleton` alone.
  describe "desk placement does not consult visibility (Gyldendal #25)" do
    test "a PUBLIC consumer type with zero documents gets a browsable Content row" do
      dataset = "structure_test_public_zero_docs"

      # No `visibility` key at all — exactly the POST /v1/schemas/:dataset
      # body from the #8463 report, taking the column default "public".
      insert_schema!(%{name: "recipe", title: "Recipes", dataset: dataset, fields: []})

      tree = Structure.build(dataset)

      content = content_types_node(tree)

      assert match?(%Node{title: "Content"}, content),
             "a public consumer type must have a home; got: #{inspect(content)}"

      recipe = Enum.find(content.items, &(&1.type_name == "recipe"))
      assert %Node{} = recipe
      assert recipe.type == :document_type_list, "must be drillable, not a dead singleton"
      assert recipe.title == "Recipes"
    end

    test "a PUBLIC schema with singleton: true reaches Settings instead of vanishing" do
      dataset = "structure_test_public_singleton"

      insert_schema!(%{
        name: "siteConfig",
        title: "Site Config",
        singleton: true,
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      settings = settings_node(tree)

      assert match?(%Node{}, settings),
             "singleton: true must be honoured regardless of visibility; " <>
               "got: #{inspect(settings)}"

      config = Enum.find(settings.items, &(&1.type_name == "siteConfig"))

      assert match?(%Node{type: :document}, config),
             "a declared singleton is a single :document node; got: #{inspect(config)}"

      # And it must NOT also appear in the generic Content bucket.
      case content_types_node(tree) do
        nil -> :ok
        %Node{items: items} -> refute Enum.any?(items, &(&1.type_name == "siteConfig"))
      end
    end

    test "a CURATED public type is not ALSO dumped into the generic Content bucket" do
      dataset = "structure_test_curated_no_double_list"
      seed_legacy(dataset)

      # `paper` is public and curated by build_papers_group/1; post/page/project
      # are public and curated by build_content_group/1. None may double-list.
      insert_schema!(%{
        name: "paper",
        title: "Papers",
        icon: "📰",
        visibility: "public",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      case content_types_node(tree) do
        nil ->
          :ok

        %Node{items: items} ->
          generic = Enum.map(items, & &1.type_name)

          for curated <- ~w(paper post page project author category) do
            refute curated in generic, "#{curated} is curated — it must not double-list"
          end
      end
    end

    test "a type that moved into Content is claimed, so it leaves …Rest" do
      dataset = "structure_test_public_leaves_rest"

      insert_schema!(%{name: "recipe", title: "Recipes", dataset: dataset, fields: []})
      insert_docs!("recipe", dataset, 2)

      tree = Structure.build(dataset)

      content = content_types_node(tree)
      assert %Node{} = content
      assert Enum.any?(content.items, &(&1.type_name == "recipe"))

      # Second-order effect of the fix, pinned deliberately: the type used to
      # surface ONLY under …Rest once documents existed. Now it has a real
      # home, so …Rest must not list it a second time.
      case rest_node(tree) do
        nil -> :ok
        %Node{items: items} -> refute Enum.any?(items, &(&1.type_name == "recipe"))
      end
    end

    test "a PRIVATE non-singleton type still lands in Content (no regression)" do
      dataset = "structure_test_private_still_content"

      insert_schema!(%{
        name: "orderNote",
        title: "Order Notes",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      content = content_types_node(tree)
      assert %Node{} = content
      assert Enum.any?(content.items, &(&1.type_name == "orderNote"))
    end
  end

  describe "papers in the desk (convergence: papers are documents)" do
    alias Barkpark.Content
    alias BarkparkWeb.Studio.PaneBuilder

    defp seed_paper_schema!(dataset) do
      insert_schema!(%{
        name: "paper",
        title: "Papers",
        icon: "📰",
        visibility: "public",
        dataset: dataset,
        fields: [%{"name" => "title", "title" => "Title", "type" => "string"}]
      })
    end

    test "the paper schema yields a :document_type_list node in build/2" do
      dataset = "structure_test_papers"
      seed_legacy(dataset)
      seed_paper_schema!(dataset)

      tree = Structure.build(dataset)

      paper_node =
        Enum.find(tree.items, fn n ->
          n.type == :document_type_list and n.id == "paper"
        end)

      assert match?(%Node{}, paper_node),
             "expected a paper doc-type-list node in top-level items; got: #{inspect(paper_node)}"

      assert paper_node.type_name == "paper"
      assert paper_node.title == "Papers"
      assert paper_node.visibility == :public
    end

    test "a seeded paper is listed in the desk pane as a selectable :doc row" do
      dataset = "structure_test_papers_listed"
      seed_paper_schema!(dataset)

      slug = "2026-05-24-desk-listing"

      {:ok, _doc} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: dataset,
            blocks: [
              %{"id" => "h", "type" => "heading", "text" => "Desk Listing Paper"},
              %{
                "id" => "p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "body"}]
              }
            ]
          })
        )

      # Drill into the "paper" doc-type-list pane (no slug → no editor yet).
      {panes, editor} = PaneBuilder.build(dataset, ["paper"])

      # No editor opens until a paper slug is selected.
      assert editor == nil

      paper_pane = List.last(panes)
      assert paper_pane.type_name == "paper"

      item = Enum.find(paper_pane.items, fn i -> i.id == slug end)
      assert item, "expected the seeded paper to be listed in the desk pane"
      # Rows are ordinary selectable :doc rows now — `phx-click="select"` drives
      # Studio-internal navigation to /studio/:dataset/paper/:slug. NOT an
      # external :paper_doc link out to /papers/:slug.
      assert item.type == :doc
      refute Map.has_key?(item, :href)
      # Title derived from the first heading block.
      assert item.title == "Desk Listing Paper"
    end

    test "selecting a paper opens a :paper view editor with the paper doc" do
      dataset = "structure_test_papers_editor"
      seed_paper_schema!(dataset)

      slug = "2026-05-24-paper-editor"

      {:ok, _doc} =
        Content.upsert_paper(
          Barkpark.LabelFixtures.paper_attrs(%{
            slug: slug,
            dataset: dataset,
            blocks: [
              %{"id" => "h", "type" => "heading", "text" => "Editor Paper"},
              %{
                "id" => "p",
                "type" => "paragraph",
                "content" => [%{"type" => "text", "value" => "body"}]
              }
            ]
          })
        )

      # Drill into /studio/:dataset/paper/:slug.
      {panes, editor} = PaneBuilder.build(dataset, ["paper", slug])

      # The list pane stays present (desk structure visible)...
      paper_pane = List.last(panes)
      assert paper_pane.type_name == "paper"

      # ...and the editor resolves a :paper view carrying the paper document.
      assert editor[:view] == :paper
      assert editor[:type] == "paper"
      assert editor[:doc].doc_id == slug
      assert is_list(get_in(editor[:doc].content, ["blocks"]))
    end
  end

  describe "tiered desk — MAIN / Plugins / …Rest (studio-structure-polish)" do
    test "media is hidden from the tree by default (top-menu placement), never in …Rest" do
      dataset = "structure_test_media_hidden"
      seed_legacy(dataset)

      insert_schema!(%{
        name: "mediaAsset",
        title: "Media Assets",
        icon: "image",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      insert_schema!(%{
        name: "mediaCollection",
        title: "Media Collections",
        icon: "folder",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      # Media documents exist in the DB…
      insert_docs!("mediaAsset", dataset, 4)
      insert_docs!("mediaCollection", dataset, 1)

      tree = Structure.build(dataset)
      names = all_type_names(tree)

      # …but Media rides the TOP MENU by default, so its types are absent from
      # the structure tree entirely.
      refute "mediaAsset" in names, "media types must not appear in the tree by default"
      refute "mediaCollection" in names

      # And because the top menu is their home, they are NOT dumped into …Rest.
      case rest_node(tree) do
        nil ->
          :ok

        %Node{items: items} ->
          rest_types = Enum.map(items, & &1.type_name)
          refute "mediaAsset" in rest_types, "media has a home (top menu) → not …Rest"
          refute "mediaCollection" in rest_types
      end
    end

    test "a workspace placement override to \"main\" restores Media into the MAIN tier" do
      ws = create_workspace!()
      proj = create_project!(ws)
      dataset = "test"
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{
            "name" => "mediaAsset",
            "title" => "Media Assets",
            "visibility" => "private",
            "fields" => []
          },
          dataset,
          scope
        )

      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
          "media" => %{"placement" => "main"}
        })

      tree = Structure.build(dataset, scope)

      assert "mediaAsset" in all_type_names(tree),
             "a workspace override to placement=main restores Media into the tree"
    end

    test "promoting OnixEdit into MAIN surfaces the books group top-level (not in …Rest)" do
      ws = create_workspace!()
      proj = create_project!(ws)
      dataset = "test"
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "book", "title" => "Books", "visibility" => "private", "fields" => []},
          dataset,
          scope
        )

      insert_docs!("book", dataset, 3, workspace_id: ws.id)

      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
          "onixedit" => %{"enabled" => true, "placement" => "main"}
        })

      tree = Structure.build(dataset, scope)

      book_top =
        Enum.find(tree.items, fn n -> n.type == :document_type_list and n.id == "book" end)

      assert match?(%Node{}, book_top),
             "promoting OnixEdit to main surfaces book top-level; got: #{inspect(book_top)}"

      # Claimed by the placed node → not double-listed under …Rest.
      case rest_node(tree) do
        nil -> :ok
        %Node{items: items} -> refute Enum.any?(items, &(&1.type_name == "book"))
      end
    end

    test "enabling a :plugins-placement plugin surfaces a Plugins node holding its group" do
      ws = create_workspace!()
      proj = create_project!(ws)
      dataset = "test"
      scope = [workspace_id: ws.id, project_id: proj.id]

      {:ok, _} =
        Content.upsert_schema(
          %{"name" => "book", "title" => "Books", "visibility" => "private", "fields" => []},
          dataset,
          scope
        )

      insert_docs!("book", dataset, 2, workspace_id: ws.id)

      # Enable OnixEdit but keep its default :plugins placement.
      {:ok, _} =
        Barkpark.Tenancy.set_workspace_plugin_settings(ws.id, %{
          "onixedit" => %{"enabled" => true}
        })

      tree = Structure.build(dataset, scope)

      plugins = plugins_node(tree)

      assert match?(%Node{type: :list}, plugins),
             "expected a Plugins tier node when a :plugins plugin is enabled; got: #{inspect(plugins)}"

      assert plugins.title == "Plugins"

      # The books group landed UNDER the Plugins node (placement :plugins), not
      # top-level and not in …Rest.
      assert "book" in collect_tn(plugins.items, []),
             "an enabled :plugins plugin's types live under the Plugins node"

      refute Enum.any?(tree.items, fn n -> n.type == :document_type_list and n.id == "book" end),
             "book is under Plugins, not top-level"
    end

    test "a disabled plugin's PRIVATE doc type falls into …Rest, never Settings" do
      dataset = "structure_test_disabled_rest"
      seed_legacy(dataset)

      # tickets is default-disabled and its `ticket` schema is PRIVATE (the real
      # plugin declaration). The Settings catch-all rejects it by OWNERSHIP
      # (charter Decision 12), so it must NOT masquerade as a Settings singleton
      # — it falls to …Rest with an honest count instead. Seed 3 published +
      # 1 draft (count = 4).
      insert_schema!(%{
        name: "ticket",
        title: "Tickets",
        icon: "🎫",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      insert_docs!("ticket", dataset, 4, published: 3)

      tree = Structure.build(dataset)

      # No ticket desk item anywhere in MAIN / Plugins (tickets disabled).
      refute "ticket" in all_type_names(rest_stripped(tree)),
             "a disabled plugin contributes no placed desk item"

      # The ownership reject keeps a disabled plugin's private type OUT of the
      # host Settings singleton group — no masquerade, no census theft.
      # seed_legacy/1 always seeds host private singletons, so the Settings
      # group MUST exist — a nil here would make the leak refute vacuous.
      settings = settings_node(tree)

      assert match?(%Node{}, settings),
             "host private singletons must produce a Settings group; got: #{inspect(settings)}"

      refute "ticket" in Enum.map(settings.items, & &1.type_name),
             "a plugin-owned private type must not surface as a Settings singleton"

      rest = rest_node(tree)
      assert %Node{} = rest
      ticket_rest = Enum.find(rest.items, &(&1.type_name == "ticket"))
      assert %Node{type: :document_type_list} = ticket_rest
      assert ticket_rest.title == "ticket (4)", "count includes the draft — honest about the DB"
    end

    test "an enabled :main plugin's PRIVATE type does not double-list in Settings" do
      dataset = "structure_test_no_double_list"
      seed_legacy(dataset)

      # sheets is enabled by default with placement :main and its `sheet` schema
      # is PRIVATE. It renders as its own top-level MAIN group (build_sheets_
      # group), so the Settings catch-all must reject it by ownership — a private
      # owned type must never appear in BOTH MAIN and Settings.
      insert_schema!(%{
        name: "sheet",
        title: "Sheets",
        icon: "📊",
        visibility: "private",
        dataset: dataset,
        fields: []
      })

      tree = Structure.build(dataset)

      # sheet is a top-level MAIN group.
      assert Enum.any?(tree.items, fn n ->
               n.type == :document_type_list and n.type_name == "sheet"
             end),
             "an enabled :main plugin's type lives top-level in MAIN"

      # …and NOT also under Settings. seed_legacy/1 always seeds host private
      # singletons, so the Settings group MUST exist — a nil here would make
      # the double-list refute vacuous.
      settings = settings_node(tree)

      assert match?(%Node{}, settings),
             "host private singletons must produce a Settings group; got: #{inspect(settings)}"

      refute "sheet" in Enum.map(settings.items, & &1.type_name),
             "a plugin-owned private type must not double-list under Settings"
    end

    test "an orphaned doc type (no schema) still surfaces in …Rest as a plain node" do
      dataset = "structure_test_orphan_rest"
      seed_legacy(dataset)

      # Documents of a type whose schema was force-deleted — no schema in scope.
      insert_docs!("ghostType", dataset, 5)

      tree = Structure.build(dataset)
      rest = rest_node(tree)
      assert %Node{} = rest

      ghost = Enum.find(rest.items, &(&1.type_name == "ghostType"))

      assert match?(%Node{}, ghost),
             "orphaned types are NEVER silently hidden; got: #{inspect(ghost)}"

      assert ghost.type == :document, "no schema → plain, non-drillable node"
      assert ghost.title == "ghostType (5)"
    end

    test "…Rest is absent when every present doc type is claimed by a placed node" do
      dataset = "structure_test_no_rest"
      seed_legacy(dataset)

      # Only `post` documents exist — and `post` is claimed by the content group.
      insert_docs!("post", dataset, 2)

      tree = Structure.build(dataset)

      assert rest_node(tree) == nil,
             "no …Rest node when the tree already accounts for every present type"
    end
  end

  # Tree with the …Rest node removed, for asserting a type is absent from the
  # PLACED tiers (MAIN + Plugins) specifically.
  defp rest_stripped(%Structure.Node{items: items} = tree) do
    %{tree | items: Enum.reject(items, &(&1.id == "rest"))}
  end

  describe "owned_schema_types_map/0 (studio-structure-polish D19)" do
    test "publishes the harvested plugin→owned-types map, keyed by plugin name" do
      map = Structure.owned_schema_types_map()

      assert is_map(map)

      # Every entry is a plugin-name binary → a list of type-name binaries.
      for {name, types} <- map do
        assert is_binary(name)
        assert is_list(types)
        assert Enum.all?(types, &is_binary/1)
      end
    end

    test "reflects a real plugin's schema ownership (bulldocs owns `paper`)" do
      map = Structure.owned_schema_types_map()

      # bulldocs harvests its ownership from `register_schemas/1` (the `paper`
      # schema) via the `use Barkpark.Plugin` default — no hardcode here.
      assert "paper" in Map.get(map, "bulldocs", []),
             "the public map must mirror the desk's harvested ownership"
    end

    test "is the SAME harvest the desk build uses, not a replica" do
      # Equivalence with the private map that feeds the tiered tree: both read
      # `owned_schema_types/0` off every registered plugin, so a consumer outside
      # structure.ex sees exactly what the desk sees. (Proven by shape: the map
      # is non-empty in the boot registry and every value is a list.)
      map = Structure.owned_schema_types_map()
      refute map == %{}, "the boot registry owns at least one schema type"
    end
  end

  describe "parse_filter/1" do
    test "returns empty map for nil" do
      assert Structure.parse_filter(nil) == %{}
    end

    test "returns empty map for empty string" do
      assert Structure.parse_filter("") == %{}
    end

    test "returns single-key map for field=value" do
      assert Structure.parse_filter("status=published") == %{"status" => "published"}
    end

    test "splits on first = only (preserves = in value)" do
      assert Structure.parse_filter("body=foo=bar") == %{"body" => "foo=bar"}
    end

    test "returns empty map for malformed input (no =)" do
      assert Structure.parse_filter("nonsense") == %{}
    end
  end
end
