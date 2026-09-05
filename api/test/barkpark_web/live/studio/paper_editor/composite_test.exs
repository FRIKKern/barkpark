defmodule BarkparkWeb.Studio.PaperEditor.CompositeTest do
  @moduledoc """
  In-Studio paper BLOCK EDITOR — v2 COMPOSITE field blocks.

    * P2.3 (barkpark-wxxa) — composite / arrayOf / codelist / localizedText
      render as a nested PaperFieldBlock LiveComponent (NOT inside
      phx-update="ignore"). The inner field components emit server-bound
      phx-change into a form targeting the component; the component recomputes
      its OWN value and sends {:paper_op, op} to the paper LiveView, which routes
      it through the canonical paper_op/2 pipeline (Content.apply_paper_block_op
      → persist + broadcast). These prove both halves: the component renders in
      Edit mode, and an inner change → handle_info({:paper_op,…}) persists the
      new structured value.
    * Polish-3 Fix 1 — arrayOf-of-composite nested-key parsing: when an
      arrayOf's `of` is a `composite`, each element's subfield inputs name
      themselves `[idx].subname`. `Plug.Conn.Query` does NOT nest through `.` or
      a leading `[`, so every such input arrives as a FLAT param key; the merge
      now sets the right `value[index][subname]` and persists it.

  Both fixtures (`seed_composite_paper!`, `seed_arraycomp_paper!`) are
  section-local. Shared base paper + `open_editor` come from
  `BarkparkWeb.PaperEditorTestHelpers`.
  """
  use BarkparkWeb.ConnCase, async: false
  use BarkparkWeb.PaperEditorTestHelpers

  # ── v2 COMPOSITE field blocks (P2.3, barkpark-wxxa) ─────────────────────────

  @composite_slug "2026-05-24-composite-paper"

  defp seed_composite_paper! do
    blocks = [
      %{
        "id" => "c-price",
        "type" => "composite",
        "label" => "Price",
        "fields" => [
          %{"name" => "amount", "title" => "Amount", "type" => "string"},
          %{"name" => "currency", "title" => "Currency", "type" => "string"}
        ],
        "value" => %{"amount" => "299", "currency" => "NOK"}
      },
      %{
        "id" => "c-keywords",
        "type" => "arrayOf",
        "label" => "Keywords",
        "ordered" => true,
        "of" => %{"name" => "keyword", "type" => "string"},
        "value" => ["history", "norway"]
      },
      %{
        "id" => "c-audience",
        "type" => "codelist",
        "label" => "Audience",
        "codelistId" => "onixedit:audience",
        "version" => 73,
        "value" => "01"
      },
      %{
        "id" => "c-blurb",
        "type" => "localizedText",
        "label" => "Blurb",
        "languages" => ["nob", "eng"],
        "format" => "plain",
        "fallbackChain" => ["nob", "eng"],
        "value" => %{"nob" => "Omtale.", "eng" => "Blurb."}
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @composite_slug,
          dataset: @dataset,
          blocks: blocks
        })
      )

    paper
  end

  test "Edit mode renders a PaperFieldBlock LiveComponent for each composite block",
       %{conn: conn} do
    seed_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))

    edit_html = open_editor(view)

    # Each composite block renders the nested LiveComponent wrapper, keyed by
    # block id, with its field-type marker — NOT a phx-update="ignore" bridge.
    for {id, type} <- [
          {"c-price", "composite"},
          {"c-keywords", "arrayOf"},
          {"c-audience", "codelist"},
          {"c-blurb", "localizedText"}
        ] do
      assert edit_html =~ ~s(id="paper-fb-#{id}")
      assert edit_html =~ ~s(data-field-type="#{type}")
    end

    # The inner field components rendered their real controls + form bindings.
    # composite: a fieldset legend with the block label + the subfield inputs
    # (CompositeField tags each subfield wrapper with data-subfield-name).
    assert edit_html =~ "Price"
    assert edit_html =~ ~s(data-subfield-name="amount")
    assert edit_html =~ ~s(data-subfield-name="currency")
    # arrayOf: ordered reorder buttons (▲/▼) and the +Add button.
    assert edit_html =~ "Keywords"
    assert edit_html =~ ~s(phx-value-action="add_row")
    assert edit_html =~ ~s(phx-value-action="move_up")
    # localizedText: one row per language.
    assert edit_html =~ ~s(data-lang="nob")
    assert edit_html =~ ~s(data-lang="eng")
    # The composite controls are NOT mounted under the leaf bridge hook.
    refute edit_html =~ ~s(id="paper-fld-c-price")
  end

  test "an inner composite change → handle_info({:paper_op,…}) persists the merged value",
       %{conn: conn} do
    seed_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))

    open_editor(view)

    pid_before = view.pid

    # Drive the inner form's phx-change targeting the LiveComponent. With
    # path="" the subfield inputs carry the bare subfield name, so the changed
    # subfields arrive flat and merge over the current %{amount, currency} map
    # (untouched subfields survive). The component sends {:paper_op, …} to the
    # paper LiveView via send(self(), …); render/1 flushes that async
    # handle_info so the patch-block lands before we read the DB. (In the
    # browser the message processes on the next loop tick automatically.)
    flush_form(view, ~s([data-block-id="c-price"] form), %{
      "amount" => "299",
      "currency" => "USD"
    })

    render(view)

    block = Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-price"))
    assert block["type"] == "composite"
    assert block["value"]["currency"] == "USD"
    # The untouched subfield survived the shallow merge.
    assert block["value"]["amount"] == "299"
    # Config + label untouched (patch-block shallow-merges only "value").
    assert block["label"] == "Price"

    # No remount — the op went through the delta path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  test "an inner localizedText change persists the merged %{lang => text} value",
       %{conn: conn} do
    seed_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))

    open_editor(view)

    flush_form(view, ~s([data-block-id="c-blurb"] form), %{
      "nob" => "Omtale.",
      "eng" => "New English blurb."
    })

    render(view)

    block = Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-blurb"))
    assert block["type"] == "localizedText"
    assert block["value"]["eng"] == "New English blurb."
    assert block["value"]["nob"] == "Omtale."
  end

  test "an inner codelist change persists the selected code", %{conn: conn} do
    seed_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))

    open_editor(view)

    # codelist renders with path="value", so the code arrives as %{"value" => …}.
    # (The codelist registry is empty in test, so the field renders its disabled
    # placeholder <select>; driving the form's phx-change directly still proves
    # the component → :paper_op → persist wiring independent of registry data.)
    flush_form(view, ~s([data-block-id="c-audience"] form), %{"value" => "02"})

    render(view)

    block =
      Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-audience"))

    assert block["type"] == "codelist"
    assert block["value"] == "02"
    assert block["codelistId"] == "onixedit:audience"
  end

  test "an arrayOf reorder (move_up) persists the reordered list", %{conn: conn} do
    seed_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))

    open_editor(view)

    # Initial order: ["history", "norway"]. Moving row index 1 up swaps them.
    view
    |> element(
      ~s([data-block-id="c-keywords"] button[phx-value-action="move_up"][phx-value-index="1"])
    )
    |> render_click(wire_params(view, %{"action" => "move_up", "index" => "1"}))

    render(view)

    block =
      Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-keywords"))

    assert block["type"] == "arrayOf"
    assert block["value"] == ["norway", "history"]
  end

  test "an arrayOf add_row appends an empty element", %{conn: conn} do
    seed_composite_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@composite_slug}"))

    open_editor(view)

    view
    |> element(~s([data-block-id="c-keywords"] button[phx-value-action="add_row"]))
    |> render_click(wire_params(view, %{"action" => "add_row"}))

    render(view)

    block =
      Content.paper_blocks(@composite_slug, @dataset) |> Enum.find(&(&1["id"] == "c-keywords"))

    assert block["value"] == ["history", "norway", ""]
  end

  # ── Polish-3 Fix 1: arrayOf-of-composite nested-key parsing ─────────────────
  #
  # When an arrayOf's `of` is a `composite`, each element's subfield inputs name
  # themselves `[idx].subname` (and `[idx].nested.subname` for a composite
  # inside the element). `Plug.Conn.Query` does NOT nest through `.` or a
  # leading `[`, so every such input arrives as a FLAT param key. The previous
  # arrayOf merge only matched bare `[idx]` keys, so composite-element subfield
  # edits were silently dropped. These prove the merge now sets the right
  # `value[index][subname]` and persists it.

  @arraycomp_slug "2026-05-24-arraycomp-paper"

  defp seed_arraycomp_paper! do
    blocks = [
      %{
        "id" => "c-contributors",
        "type" => "arrayOf",
        "label" => "Contributors",
        "ordered" => true,
        "of" => %{
          "name" => "contributor",
          "type" => "composite",
          "fields" => [
            %{"name" => "name", "title" => "Name", "type" => "string"},
            %{"name" => "role", "title" => "Role", "type" => "string"}
          ]
        },
        "value" => [
          %{"name" => "Ada Lovelace", "role" => "Author"},
          %{"name" => "Grace Hopper", "role" => "Editor"}
        ]
      }
    ]

    {:ok, paper} =
      Content.upsert_paper(
        Barkpark.LabelFixtures.paper_attrs(%{
          slug: @arraycomp_slug,
          dataset: @dataset,
          blocks: blocks
        })
      )

    paper
  end

  test "an inner-change on a composite element subfield inside an arrayOf updates the right nested value + persists",
       %{conn: conn} do
    seed_arraycomp_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@arraycomp_slug}"))

    open_editor(view)

    pid_before = view.pid

    # The composite-element subfield inputs name themselves `[idx].subname`.
    # Edit element 1's `role` (Editor → Maintainer); the merge must set
    # value[1][role] and leave element 0 + element 1's name untouched.
    flush_form(view, ~s([data-block-id="c-contributors"] form), %{
      "[1].role" => "Maintainer"
    })

    render(view)

    block =
      Content.paper_blocks(@arraycomp_slug, @dataset)
      |> Enum.find(&(&1["id"] == "c-contributors"))

    assert block["type"] == "arrayOf"
    # The edited subfield landed at value[1][role].
    assert Enum.at(block["value"], 1)["role"] == "Maintainer"
    # The other subfield of the same element survived.
    assert Enum.at(block["value"], 1)["name"] == "Grace Hopper"
    # Element 0 is wholly untouched.
    assert Enum.at(block["value"], 0) == %{"name" => "Ada Lovelace", "role" => "Author"}
    # No remount — the op went through the canonical delta path.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)
  end

  test "editing two subfields of the same arrayOf composite element in one change merges both",
       %{conn: conn} do
    seed_arraycomp_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@arraycomp_slug}"))

    open_editor(view)

    flush_form(view, ~s([data-block-id="c-contributors"] form), %{
      "[0].name" => "Augusta Ada",
      "[0].role" => "Mathematician"
    })

    render(view)

    block =
      Content.paper_blocks(@arraycomp_slug, @dataset)
      |> Enum.find(&(&1["id"] == "c-contributors"))

    assert Enum.at(block["value"], 0) == %{"name" => "Augusta Ada", "role" => "Mathematician"}
    # The second element is preserved (list not truncated by the partial change).
    assert Enum.at(block["value"], 1) == %{"name" => "Grace Hopper", "role" => "Editor"}
  end

  # ── Unbounded-alloc guard: hostile bracket index ────────────────────────────
  #
  # A crafted form-change key like `[99999999999]` would (pre-fix) make the
  # arrayOf merge build a `0..99999999999` list + pad with billions of nils,
  # OOMing the whole BEAM. The `@max_array_index` reject drops such keys wholesale
  # while sane siblings in the same change still apply.
  test "an inner-change with an oversized bracket index is ignored and does not OOM the BEAM",
       %{conn: conn} do
    seed_arraycomp_paper!()

    {:ok, view, _html} =
      live(conn, scoped_studio("/d/#{@dataset}/studio/paper/#{@arraycomp_slug}"))

    open_editor(view)

    pid_before = view.pid

    # One event carrying a hostile key alongside a sane sibling edit. The hostile
    # key must be dropped (no giant alloc), the sane edit must still land.
    flush_form(view, ~s([data-block-id="c-contributors"] form), %{
      "[99999999999]" => "x",
      "[0].role" => "Maintainer"
    })

    render(view)

    # The LiveView survived — no OOM crash.
    assert view.pid == pid_before
    assert Process.alive?(view.pid)

    block =
      Content.paper_blocks(@arraycomp_slug, @dataset)
      |> Enum.find(&(&1["id"] == "c-contributors"))

    # The list stayed at the seeded length — the hostile index grew nothing.
    assert length(block["value"]) == 2
    # The sane sibling edit still applied.
    assert Enum.at(block["value"], 0)["role"] == "Maintainer"
    assert Enum.at(block["value"], 1) == %{"name" => "Grace Hopper", "role" => "Editor"}
  end

  # ── Crash-class closure: unknown phx event on the PaperFieldBlock component ──
  #
  # #819: a stale/forged phx-value targeting the nested LiveComponent used to
  # FunctionClauseError-crash the parent paper LiveView (the component's
  # handle_event/3 had only "inner-change" / "inner-array-op" heads). The
  # trailing catch-all no-ops it. A LiveComponent event can't be driven through
  # render_hook (no phx-hook on the form), so we exercise the callback directly —
  # the same unit-call shape the cycle-44 crash-class test uses for `Bulk`.
  test "an unknown/stale phx event on the PaperFieldBlock component no-ops (catch-all)" do
    socket = %Phoenix.LiveView.Socket{}

    assert {:noreply, ^socket} =
             BarkparkWeb.Studio.PaperFieldBlock.handle_event(
               "totally-unknown-stale-event",
               %{"leftover" => "true"},
               socket
             )
  end

  test "a correlated field save keeps its local value until the parent echoes persistence" do
    block = %{
      "id" => "c-price",
      "type" => "composite",
      "label" => "Price",
      "fields" => [%{"name" => "amount", "title" => "Amount", "type" => "string"}],
      "value" => %{"amount" => "299"}
    }

    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}

    assert {:ok, socket} =
             BarkparkWeb.Studio.PaperFieldBlock.update(
               %{id: "paper-fb-c-price", block: block},
               socket
             )

    request_id = Ecto.UUID.generate()

    assert {:noreply, pending_socket} =
             BarkparkWeb.Studio.PaperFieldBlock.handle_event(
               "inner-flush",
               %{"request_id" => request_id, "if_rev" => 1, "values" => %{"amount" => "399"}},
               socket
             )

    assert_receive {:paper_op,
                    %{
                      "op" => "patch-block",
                      "id" => "c-price",
                      "patch" => %{"value" => %{"amount" => "399"}}
                    }, ^request_id}

    # A refused write causes the parent to render the old persisted block. The
    # component keeps the draft so the next View attempt can retry it.
    assert {:ok, refused_socket} =
             BarkparkWeb.Studio.PaperFieldBlock.update(
               %{id: "paper-fb-c-price", block: block},
               pending_socket
             )

    assert refused_socket.assigns.value == %{"amount" => "399"}
    assert refused_socket.assigns.pending_value?

    echoed_block = put_in(block, ["value", "amount"], "399")

    assert {:ok, confirmed_socket} =
             BarkparkWeb.Studio.PaperFieldBlock.update(
               %{id: "paper-fb-c-price", block: echoed_block},
               refused_socket
             )

    assert confirmed_socket.assigns.value == %{"amount" => "399"}
    refute confirmed_socket.assigns.pending_value?
  end

  defp paper_rev(view), do: :sys.get_state(view.pid).socket.assigns.paper_rev

  defp wire_params(view, params) do
    Map.merge(params, %{"request_id" => Ecto.UUID.generate(), "if_rev" => paper_rev(view)})
  end

  defp flush_form(view, selector, values) do
    target = element(view, selector)
    render_change(target, values)

    render_hook(target, "inner-flush", %{
      "request_id" => Ecto.UUID.generate(),
      "if_rev" => paper_rev(view),
      "values" => values
    })
  end
end
