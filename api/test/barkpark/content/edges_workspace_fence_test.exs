defmodule Barkpark.Content.EdgesWorkspaceFenceTest do
  @moduledoc """
  TENANCY hardening (task-4b942de098205a47): `Content.Edges.list_outbound_edges/2`
  and `list_inbound_edges/2` filter on `from_id`/`to_id` (+ optional `:kind`)
  and carried NO tenant fence of their own, while their sibling
  `extract_edges/2` goes through `WriteScope.scope_to_dataset` +
  `scope_to_workspace_or_global`.

  Not a live leak: `from_id`/`to_id` are `documents.id` binary-id PKs and every
  caller on origin/main seeds them from a scoped PK resolution. The fence is
  DEFENCE-IN-DEPTH, so the safety stops living entirely in the callers.

  ## The omitted-bind answer this file pins

  Omitting `:workspace_id` is PERMITTED (explicit global read, byte-identical to
  the pre-bind behaviour), NOT refused. `omits the bind` below is the test that
  reds if anyone silently flips that answer to a refusal or to a fail-closed
  empty.

  ## Non-vacuity

  Deleting the `maybe_scope_edges_to_workspace/2` pipe from both functions in
  `api/lib/barkpark/content/edges.ex` reds 5 of these 8 tests — every test that
  supplies a bind, plus the `:shared_only` one. The POSITIVE CONTROL and the two
  backward-compatibility tests stay GREEN in BOTH states, which is the point:
  the bind narrows to the tenant, it does not disable the scan and it does not
  move an unbound caller. Run output is quoted in the PR body.
  """
  use Barkpark.DataCase, async: true

  alias Barkpark.Content
  alias Barkpark.Content.{Document, Edge}
  alias Barkpark.Repo
  alias Barkpark.TenancyFixtures

  # Deliberately ONE dataset string across both workspaces — isolation must come
  # from workspace_id, never from the dataset leaf.
  @dataset "edges-fence"

  defp doc_in!(workspace, doc_id) do
    {:ok, doc} =
      %Document{}
      |> Document.changeset(%{
        "doc_id" => doc_id,
        "type" => "post",
        "dataset" => @dataset,
        "title" => doc_id,
        "status" => "published",
        "rev" => "rev-#{doc_id}",
        "workspace_id" => workspace.id
      })
      |> Repo.insert()

    doc
  end

  defp edge!(from_doc, to_doc, kind) do
    {:ok, edge} =
      %Edge{}
      |> Edge.changeset(%{from_id: from_doc.id, to_id: to_doc.id, kind: kind})
      |> Repo.insert()

    edge
  end

  setup do
    ws_a = TenancyFixtures.create_workspace!()
    ws_b = TenancyFixtures.create_workspace!()

    # ONE pk on both sides of the fence: `hub` lives in workspace A and has an
    # edge to a workspace-A doc AND an edge to a workspace-B doc, plus inbound
    # edges from one doc in each workspace. A cross-tenant edge is the row the
    # projector's own strict scope would never write — seeded DIRECTLY here
    # precisely because the read must not depend on the writer for its fence.
    hub = doc_in!(ws_a, "hub")
    a_out = doc_in!(ws_a, "a-out")
    b_out = doc_in!(ws_b, "b-out")
    a_in = doc_in!(ws_a, "a-in")
    b_in = doc_in!(ws_b, "b-in")

    %{
      ws_a: ws_a,
      ws_b: ws_b,
      hub: hub,
      out_a: edge!(hub, a_out, "rel"),
      out_b: edge!(hub, b_out, "rel"),
      in_a: edge!(a_in, hub, "rel"),
      in_b: edge!(b_in, hub, "rel")
    }
  end

  defp ids(edges), do: edges |> Enum.map(& &1.id) |> Enum.sort()

  describe "workspace bind supplied" do
    test "list_outbound_edges/2 returns no edge belonging to another workspace", ctx do
      unbound = Content.list_outbound_edges(ctx.hub.id)

      assert ids(unbound) == ids([ctx.out_a, ctx.out_b]),
             "precondition: without the bind BOTH workspaces' edges are visible"

      bound = Content.list_outbound_edges(ctx.hub.id, workspace_id: ctx.ws_a.id)

      assert ids(bound) == [ctx.out_a.id]
      refute Enum.any?(bound, &(&1.id == ctx.out_b.id))
    end

    test "list_inbound_edges/2 returns no edge belonging to another workspace", ctx do
      unbound = Content.list_inbound_edges(ctx.hub.id)

      assert ids(unbound) == ids([ctx.in_a, ctx.in_b]),
             "precondition: without the bind BOTH workspaces' edges are visible"

      bound = Content.list_inbound_edges(ctx.hub.id, workspace_id: ctx.ws_a.id)

      assert ids(bound) == [ctx.in_a.id]
      refute Enum.any?(bound, &(&1.id == ctx.in_b.id))
    end

    test "the NEAR endpoint is bound too — a foreign pk yields nothing", ctx do
      assert Content.list_outbound_edges(ctx.hub.id, workspace_id: ctx.ws_b.id) == []
      assert Content.list_inbound_edges(ctx.hub.id, workspace_id: ctx.ws_b.id) == []
    end

    test "the bind composes with :kind rather than replacing it", ctx do
      other = doc_in!(ctx.ws_a, "a-out-alt")
      alt = edge!(ctx.hub, other, "alt")

      assert ids(Content.list_outbound_edges(ctx.hub.id, workspace_id: ctx.ws_a.id)) ==
               ids([ctx.out_a, alt])

      assert ids(Content.list_outbound_edges(ctx.hub.id, workspace_id: ctx.ws_a.id, kind: "alt")) ==
               [alt.id]
    end
  end

  describe "POSITIVE CONTROL — the bind cannot pass by returning nothing" do
    test "every edge of a single-workspace population is still returned", ctx do
      # Every seeded edge in the SAME workspace as the bind. Built fresh so the
      # control's population is exactly what it asserts over.
      hub = doc_in!(ctx.ws_a, "ctl-hub")

      out_edges =
        for n <- 1..3, do: edge!(hub, doc_in!(ctx.ws_a, "ctl-out-#{n}"), "rel")

      in_edges =
        for n <- 1..3, do: edge!(doc_in!(ctx.ws_a, "ctl-in-#{n}"), hub, "rel")

      # THE EMPTY-POPULATION GUARD: if the seeding ever stops producing rows the
      # control below would "pass" by comparing [] == []. Assert the population
      # is non-empty FIRST, so an empty scan fails here instead of passing there.
      assert length(out_edges) > 0
      assert length(in_edges) > 0

      bound_out = Content.list_outbound_edges(hub.id, workspace_id: ctx.ws_a.id)
      bound_in = Content.list_inbound_edges(hub.id, workspace_id: ctx.ws_a.id)

      assert length(bound_out) > 0, "the bound outbound scan returned NOTHING — vacuous control"
      assert length(bound_in) > 0, "the bound inbound scan returned NOTHING — vacuous control"

      assert ids(bound_out) == ids(out_edges)
      assert ids(bound_in) == ids(in_edges)

      # And the bind changed nothing about what an unbound scan of the same
      # single-workspace population sees.
      assert ids(bound_out) == ids(Content.list_outbound_edges(hub.id))
      assert ids(bound_in) == ids(Content.list_inbound_edges(hub.id))
    end
  end

  describe "backward compatibility — a caller that supplies no bind" do
    test "omits the bind: the read stays an EXPLICIT GLOBAL read (permitted, not refused)", ctx do
      # THE OMITTED-BIND CONTRACT. This is the criterion-4 lock: the chosen
      # answer is PERMITTED — no bind means the pre-existing cross-workspace
      # result, not a raise and not a fail-closed empty. A silent flip to
      # either reds here.
      assert ids(Content.list_outbound_edges(ctx.hub.id)) == ids([ctx.out_a, ctx.out_b])
      assert ids(Content.list_inbound_edges(ctx.hub.id)) == ids([ctx.in_a, ctx.in_b])

      # An explicit nil is the same as omitting the key.
      assert ids(Content.list_outbound_edges(ctx.hub.id, workspace_id: nil)) ==
               ids([ctx.out_a, ctx.out_b])

      assert ids(Content.list_inbound_edges(ctx.hub.id, workspace_id: nil)) ==
               ids([ctx.in_a, ctx.in_b])
    end

    test "the no-bind call shapes the derived caller set actually uses are unchanged", ctx do
      # Content.Graph.neighbor_edges/4 passes `edge_opts(opts)` — either `[]` or
      # `[kind: <single>]`; EdgeProjector.Projector passes NO opts at all.
      # Both shapes must be byte-identical to the pre-bind behaviour.
      assert ids(Content.list_outbound_edges(ctx.hub.id, [])) == ids([ctx.out_a, ctx.out_b])
      assert ids(Content.list_inbound_edges(ctx.hub.id, [])) == ids([ctx.in_a, ctx.in_b])

      assert ids(Content.list_outbound_edges(ctx.hub.id, kind: "rel")) ==
               ids([ctx.out_a, ctx.out_b])

      assert Content.list_outbound_edges(ctx.hub.id, kind: "nope") == []
    end

    test ":shared_only binds the SHARED layer (workspace_id IS NULL), never every tenant", ctx do
      # `BarkparkWeb.ScopeHelpers.scope_opts/1` emits :shared_only for a request
      # that resolved no workspace. It must mean the global/NULL layer.
      global_hub =
        Repo.insert!(
          Document.changeset(%Document{}, %{
            "doc_id" => "global-hub",
            "type" => "post",
            "dataset" => @dataset,
            "title" => "global-hub",
            "status" => "published",
            "rev" => "rev-global-hub"
          })
        )

      global_target =
        Repo.insert!(
          Document.changeset(%Document{}, %{
            "doc_id" => "global-target",
            "type" => "post",
            "dataset" => @dataset,
            "title" => "global-target",
            "status" => "published",
            "rev" => "rev-global-target"
          })
        )

      assert is_nil(global_hub.workspace_id) and is_nil(global_target.workspace_id)

      global_edge = edge!(global_hub, global_target, "rel")
      tenant_edge = edge!(global_hub, doc_in!(ctx.ws_a, "ws-a-from-global"), "rel")

      shared = Content.list_outbound_edges(global_hub.id, workspace_id: :shared_only)

      assert ids(shared) == [global_edge.id]
      refute Enum.any?(shared, &(&1.id == tenant_edge.id))
    end
  end
end
