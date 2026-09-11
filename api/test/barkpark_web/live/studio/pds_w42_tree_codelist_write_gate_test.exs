defmodule BarkparkWeb.Studio.PdsW42TreeCodelistWriteGateTest do
  @moduledoc """
  pds-w42-bl-tree-codelist-readonly-guard-inert — the tree-codelist picker's
  `readonly` guard, and the write chain it never stood in front of.

  MECHANISM (source, not prose). `TreeCodelistField.handle_event(
  "tree_node_select", …)` opens with `if socket.assigns.readonly do {:noreply,
  socket}`. On the Studio path that branch is unreachable: `PaperFieldBlock`'s
  `codelist`+`variant: "tree"` render head mounts `TreeCodelistField` with
  `field/value/on_change/plugin_name/list_id/input_name/notify_id` and NO
  `readonly`, so the component's own `mount/1` default (`readonly: false`)
  stands for every principal. The one callsite that DOES pass `readonly`
  (`codelist_field.ex`) passes no `notify_id`, so `maybe_notify_select/2`
  short-circuits on the `nil` head and that path cannot write at all. Guard and
  danger were disjoint by construction.

  THE CHAIN, three hops, all hook-invisible:

      cid `tree_node_select`
        -> send(self(), {:tree_codelist_change, %{id:, value:}})   (handle_INFO)
        -> StudioLive handle_info -> Lifecycle.tree_codelist_change/2
        -> send_update(PaperFieldBlock, tree_value: code)
        -> PaperFieldBlock.update(%{tree_value: …}) -> persist/2
        -> send(self(), {:paper_op, …})                            (handle_INFO)
        -> Shared.Paper.paper_op/2 -> the store

  WHAT WAS AND WAS NOT AT RISK. The chokepoint gate (pds-w42, shared/paper.ex
  `write_denied?/1`) already refuses the terminal `{:paper_op, …}`, so
  PERSISTED state was never reachable this way — the first test here pins that
  as the control, on origin/main and after. What WAS reachable is everything
  before the chokepoint: `send_update` runs `PaperFieldBlock.update/2`, which
  assigns the forged code to the component's OWN `:value` and sets
  `pending_value?`, so a write-denied principal's editor renders the picked
  code back as though the save had landed, and that pending value is retained
  across the parent's echo by design. The second test measures exactly that,
  through the rendered hidden input the component writes.

  THE FIX asks the write question at the first place that HOLDS a principal —
  `Lifecycle.tree_codelist_change/2`, on the parent socket — using
  `Shared.Paper.write_denied?/1` and `grant_target_denied?/3`, the same copies
  the chokepoint asks, in the same order. No forked predicate, and no
  capability prop on a component that cannot authorize anything.

  `async: false` — the canvas flag is a process-global env var.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.{Auth, Content}
  alias Barkpark.Content.Codelists
  alias BarkparkWeb.Studio.Caps

  @dataset "production"
  @readonly "pds-w42-tree-readonly"
  @writer "pds-w42-tree-writer"
  @block_id "fb-thema"
  @plugin "onixedit"
  @list_id "onixedit:tree-gate-proof"
  @old_code "FBA"
  @forged_code "ESCALATED"

  setup do
    prev = System.get_env("BARKPARK_PAPER_CANVAS")

    on_exit(fn ->
      case prev do
        nil -> System.delete_env("BARKPARK_PAPER_CANVAS")
        v -> System.put_env("BARKPARK_PAPER_CANVAS", v)
      end
    end)

    seed_paper_schema!()
    seed_codelist!()

    {:ok, _} = Auth.create_token(@readonly, "pds w42 tree readonly", @dataset, ["read"])
    {:ok, _} = Auth.create_token(@writer, "pds w42 tree writer", @dataset, ["read", "write"])

    :ok
  end

  defp seed_paper_schema! do
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "paper",
          "title" => "Papers",
          "icon" => "📰",
          "visibility" => "public",
          "fields" => [%{"name" => "title", "title" => "Title", "type" => "string"}]
        },
        @dataset
      )
  end

  # A REAL parent/child codelist, not the `tree_loader` stub: the Studio render
  # head passes no loader, so the component loads through
  # `Codelists.tree/3` exactly as it does in production. A non-empty tree also
  # makes the component render its hidden `<input data-tree-selected="true">`,
  # which is the surface the second test measures.
  defp seed_codelist! do
    {:ok, _} =
      Codelists.register(@plugin, @list_id, %{
        issue: "1",
        name: "Tree gate proof",
        values: [
          %{
            code: "FB",
            translations: [%{language: "eng", label: "Fiction"}],
            children: [
              %{code: @old_code, translations: [%{language: "eng", label: "Modern fiction"}]},
              %{code: @forged_code, translations: [%{language: "eng", label: "Escalated"}]}
            ]
          }
        ]
      })
  end

  # A paper carrying ONE v2 `codelist` block in the TREE variant — the block
  # shape whose render head mounts `TreeCodelistField` with `notify_id`.
  defp create_paper!(slug) do
    blocks = [
      %{"id" => "h-1", "type" => "heading", "text" => "W42 tree"},
      %{
        "id" => @block_id,
        "type" => "codelist",
        "label" => "Subject",
        "variant" => "tree",
        "plugin" => @plugin,
        "codelistId" => @list_id,
        "value" => @old_code
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{slug: slug, dataset: @dataset, blocks: blocks})
      )

    paper
  end

  # The codelist block's value as PERSISTED STATE reports it — read back from
  # the store, never from an assign.
  defp stored_value(slug) do
    paper = Content.get_paper(slug, @dataset)

    blocks =
      get_in(paper.content, ["blocks"]) || get_in(paper.content, ["body", "blocks"]) || []

    blocks
    |> Enum.find(%{}, &(Map.get(&1, "id") == @block_id))
    |> Map.get("value")
  end

  defp open!(conn, token, slug) do
    {:ok, view, _html} =
      conn
      |> Plug.Test.init_test_session(%{"api_token" => token})
      |> live(scoped_studio("/d/#{@dataset}/studio/paper/#{slug}"))

    view
  end

  defp socket_of(view), do: :sys.get_state(view.pid).socket
  defp flash_error(view), do: socket_of(view).assigns.flash["error"]

  defp assert_write_denied_socket!(view) do
    socket = socket_of(view)
    caps = Caps.derive(socket)
    assert caps.write == false
    assert Caps.write_capable?(socket.assigns, caps) == false
    :ok
  end

  # THE CHAIN, driven at its real entry point: the cid-targeted
  # `tree_node_select` on the nested TreeCodelistField. The trailing `render/1`
  # forces the parent to drain BOTH handle_info hops before anything is read —
  # reading straight after `render_hook/3` reads before the messages are
  # processed and reports a false "no write".
  defp tree_node_select(view, code) do
    view
    |> with_target("#tree-" <> @block_id)
    |> render_hook("tree_node_select", %{"code" => code})

    render(view)
    :ok
  end

  # What the component's OWN value is, as the editor renders it back: the
  # hidden input TreeCodelistField writes from its `:selected` assign, which
  # PaperFieldBlock re-feeds from its `:value` on every parent render.
  defp rendered_tree_value(view) do
    case Regex.run(
           ~r/<input[^>]*data-tree-selected="true"[^>]*>/,
           render(view)
         ) do
      [tag] -> Regex.run(~r/value="([^"]*)"/, tag) |> List.last()
      nil -> :no_hidden_input
    end
  end

  describe "a write-denied principal driving the tree-codelist select chain" do
    test "the chain is refused and persisted state is unchanged", %{conn: conn} do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      slug = "pds-w42-tree-denied"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)

      # PRECONDITION, not assumed: the tree component really is mounted with a
      # notify_id (the render head that has one), and the codelist really did
      # load — an empty tree renders the disabled placeholder instead and the
      # chain would be untestable.
      html = render(view)
      assert html =~ ~s(id="tree-#{@block_id}")
      assert html =~ ~s(data-tree-selected="true")
      assert rendered_tree_value(view) == @old_code

      tree_node_select(view, @forged_code)

      assert flash_error(view) == "You don't have access to do that."
      assert stored_value(slug) == @old_code
    end

    test "the component's own value does not move either — no forged code echoed back",
         %{conn: conn} do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      slug = "pds-w42-tree-echo"
      create_paper!(slug)

      view = open!(conn, @readonly, slug)
      assert_write_denied_socket!(view)
      assert rendered_tree_value(view) == @old_code

      tree_node_select(view, @forged_code)

      # NON-VACUOUS: revert the gate in Lifecycle.tree_codelist_change/2 and
      # this prints `left: "ESCALATED"` — send_update reaches
      # PaperFieldBlock.update/2, which assigns the forged code and marks it
      # pending, so the denied principal's editor renders it back.
      assert rendered_tree_value(view) == @old_code
      assert stored_value(slug) == @old_code
    end
  end

  describe "the CONTROL — the same chain for a write-CAPABLE principal" do
    test "a writer's row select still travels the whole chain to the store", %{conn: conn} do
      System.delete_env("BARKPARK_PAPER_CANVAS")
      slug = "pds-w42-tree-writer"
      create_paper!(slug)

      view = open!(conn, @writer, slug)

      socket = socket_of(view)
      assert Caps.write_capable?(socket.assigns, Caps.derive(socket)) == true
      assert rendered_tree_value(view) == @old_code

      tree_node_select(view, @forged_code)

      # The gate must not have frozen the legitimate path: this is what proves
      # the denial above is about the PRINCIPAL and not about the chain being
      # broken for everyone.
      assert stored_value(slug) == @forged_code
      assert rendered_tree_value(view) == @forged_code
    end
  end
end
