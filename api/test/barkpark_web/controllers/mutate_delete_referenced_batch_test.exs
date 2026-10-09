defmodule BarkparkWeb.MutateDeleteReferencedBatchTest do
  @moduledoc """
  task-6b5e4b3e572d38c9 — batches the reference-integrity check
  `ensure_unreferenced/5` runs across a whole RUN of consecutive `"delete"`
  mutations, instead of once per delete. Follow-up to task-c801daf4efd35a74
  (#22499), which added a flat 50-delete cap because `delete` consumed ZERO
  quota room and `Content.Edges.find_referencing_docs/3` ran once PER
  delete — a query per reference-typed field across every schema, PER
  delete — O(deletes × reference fields) queries inside one transaction.

  THE FIX pins three things test-first:

    * a long consecutive run of deletes succeeds and stays fast (not
      merely "doesn't 500" — the whole point is the query count no longer
      scales with the run's length).
    * refusal semantics for an EXTERNAL referrer (something NOT in the same
      delete run) are byte-identical to the single-id path: still 409
      `document_referenced`, still names the referrer.
    * the ONE deliberate behaviour refinement batching introduces: two
      documents in the SAME run that reference each other no longer block
      one another (both vanish together in the same atomic transaction
      regardless of processing order) — the single-id path was
      order-dependent for exactly this case.

  `force: true` and a lone delete mixed into a non-delete batch (the
  single-id path, untouched by this work) are also pinned, so the two code
  paths (`apply_chunk/5`'s batched arm vs. its single-mutation arm) both
  stay correct.
  """
  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Repo, Tenancy}
  alias Barkpark.Tenancy.Auth, as: TenancyAuth

  import Ecto.Query

  @dataset "mdrb_ds"

  setup do
    suffix = System.unique_integer([:positive])
    {:ok, ws} = Tenancy.create_workspace(%{slug: "mdrb-ws-#{suffix}", name: "Batch Ref"})
    {:ok, proj} = Tenancy.create_project(ws, %{slug: "default", name: "Default"})
    scope = [workspace_id: ws.id, project_id: proj.id]

    {:ok, _} =
      Content.upsert_schema(
        %{"name" => "author", "title" => "Author", "visibility" => "public", "fields" => []},
        @dataset,
        scope
      )

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => "post",
          "title" => "Post",
          "visibility" => "public",
          "fields" => [
            %{"name" => "author", "type" => "reference", "refType" => "author"},
            %{"name" => "reviewer", "type" => "reference", "refType" => "author"},
            %{"name" => "related", "type" => "reference", "refType" => "post"},
            %{"name" => "topic", "type" => "reference", "refType" => "author"}
          ]
        },
        @dataset,
        scope
      )

    raw = "mdrb-token-#{suffix}"
    {:ok, token} = Auth.create_token(raw, "mdrb writer", @dataset, ["read", "write"])
    {:ok, _} = TenancyAuth.create_membership(ws.id, token.id)

    {:ok, ws: ws, proj: proj, slug: ws.slug, raw: raw}
  end

  defp mutate(conn, slug, raw, mutations) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
    |> post(
      "/w/#{slug}/p/default/v1/data/mutate/#{@dataset}",
      Jason.encode!(%{"mutations" => mutations})
    )
  end

  defp create(id, attrs \\ %{}) do
    %{"create" => Map.merge(%{"_type" => "post", "_id" => id, "title" => id}, attrs)}
  end

  defp delete_op(id, extra \\ %{}) do
    %{"delete" => Map.merge(%{"id" => id, "type" => "post"}, extra)}
  end

  defp body(conn), do: Jason.decode!(conn.resp_body)

  test "a batch of 250 consecutive deletes (several reference fields, no cross-refs) succeeds",
       %{conn: conn, slug: slug, raw: raw} do
    ids = for i <- 1..250, do: "mdrb-#{i}"
    seed = mutate(conn, slug, raw, Enum.map(ids, &create/1))
    assert seed.status == 200, "seeding failed: #{seed.status} #{seed.resp_body}"

    resp = mutate(conn, slug, raw, Enum.map(ids, &delete_op/1))

    assert resp.status == 200, "#{resp.status} #{resp.resp_body}"
    assert length(body(resp)["results"]) == 250
  end

  # task-6b5e4b3e572d38c9 review (main red, run 37956140637): the sibling
  # test above used to ALSO assert a wall-clock ceiling on the HTTP request
  # ("stays fast"). CI measured 3836ms against a 3000ms bound -- a
  # load-dependent number that will always eventually flap, on a box this
  # test does not control. What the batching claim actually says is a QUERY
  # COUNT claim ("one pass per reference field, not one per field per
  # delete"), so prove THAT directly: call the batched function itself for
  # two very different id-list sizes and assert the query count is the
  # same -- deterministic, independent of machine speed or load, and a
  # tighter proof than timing ever was (a flat query count PROVES the
  # multiplier is gone; a fast wall-clock time merely suggests it).
  test "the batched reference-integrity query count is independent of the delete-run length", %{
    conn: conn,
    slug: slug,
    raw: raw,
    ws: ws,
    proj: proj
  } do
    ids250 = for i <- 1..250, do: "mdrb-qc-#{i}"
    seed = mutate(conn, slug, raw, Enum.map(ids250, &create/1))
    assert seed.status == 200, "seeding failed: #{seed.status} #{seed.resp_body}"

    ids50 = Enum.take(ids250, 50)
    scope = [workspace_id: ws.id, project_id: proj.id]

    {_, count250} =
      Barkpark.QueryCounter.count(fn ->
        Barkpark.Content.ReferenceIntegrity.referrers_for_ids(ids250, @dataset, scope)
      end)

    {_, count50} =
      Barkpark.QueryCounter.count(fn ->
        Barkpark.Content.ReferenceIntegrity.referrers_for_ids(ids50, @dataset, scope)
      end)

    assert count250 == count50,
           "query count scaled with the id-list length: #{count50} queries for 50 ids, " <>
             "#{count250} for 250 -- the whole point of batching is that this is flat " <>
             "(one pass per reference field), not O(ids)"

    assert count250 > 0, "the measurement counted nothing -- this assertion would pass vacuously"
  end

  test "an EXTERNAL referrer still blocks the whole batched run, 409 naming the referrer", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    seed =
      mutate(conn, slug, raw, [
        create("mdrb-target"),
        create("mdrb-referrer", %{"author" => %{"_type" => "reference", "_ref" => "mdrb-target"}})
      ])

    assert seed.status == 200

    ids = for i <- 1..5, do: "mdrb-leaf-#{i}"
    seed2 = mutate(conn, slug, raw, Enum.map(ids, &create/1))
    assert seed2.status == 200

    # A run of 6 consecutive deletes: 5 unreferenced leaves + the referenced
    # target, in the MIDDLE of the run -- exercises the batched path with a
    # real external block, not just an all-succeed run.
    batch =
      Enum.map(Enum.take(ids, 2), &delete_op/1) ++
        [delete_op("mdrb-target")] ++ Enum.map(Enum.drop(ids, 2), &delete_op/1)

    resp = mutate(conn, slug, raw, batch)

    assert resp.status == 409
    err = body(resp)["error"]
    assert err["code"] == "document_referenced"
    assert err["details"]["id"] == "mdrb-target"
    assert err["details"]["referrers"] == [%{"id" => "drafts.mdrb-referrer", "type" => "post"}]

    # All-or-nothing: the whole batch rolled back, including the leaves that
    # had no referrer at all.
    assert match?({:ok, _}, Content.get_document("drafts.mdrb-leaf-1", "post", @dataset, []))
  end

  test "force: true inside a batched run still deletes and still audits", %{
    conn: conn,
    slug: slug,
    raw: raw
  } do
    seed =
      mutate(conn, slug, raw, [
        create("mdrb-forced-target"),
        create("mdrb-forced-referrer", %{
          "author" => %{"_type" => "reference", "_ref" => "mdrb-forced-target"}
        })
      ])

    assert seed.status == 200

    others = for i <- 1..3, do: "mdrb-forced-leaf-#{i}"
    seed2 = mutate(conn, slug, raw, Enum.map(others, &create/1))
    assert seed2.status == 200

    batch =
      Enum.map(others, &delete_op/1) ++ [delete_op("mdrb-forced-target", %{"force" => true})]

    resp = mutate(conn, slug, raw, batch)
    assert resp.status == 200, "#{resp.status} #{resp.resp_body}"

    assert Content.get_document("mdrb-forced-target", "post", @dataset, []) ==
             {:error, :not_found}

    event =
      from(e in Barkpark.Audit.Event,
        where: e.action == "document.delete_forced" and e.subject == "mdrb-forced-target"
      )
      |> Repo.one()

    assert event, "the forced delete inside a batched run must still write its audit event"
  end

  test "a one-way reference, both docs deleted in the SAME batch, succeeds in the order that used to block",
       %{
         conn: conn,
         slug: slug,
         raw: raw
       } do
    # Y -> X, one-way (X does NOT reference Y back). The single-id, sequential
    # path is ORDER-DEPENDENT for exactly this shape: deleting Y first, then X,
    # always worked (Y is gone by the time X's referrer-check runs, in the
    # SAME transaction); deleting X FIRST, with Y still live, finds Y as a
    # referrer and 409s the whole batch -- a real, pre-existing inconsistency
    # this batching incidentally fixes. This test pins the X-first order,
    # the one that used to fail.
    seed =
      mutate(conn, slug, raw, [
        create("mdrb-order-x"),
        create("mdrb-order-y", %{"related" => %{"_type" => "reference", "_ref" => "mdrb-order-x"}})
      ])

    assert seed.status == 200

    resp = mutate(conn, slug, raw, [delete_op("mdrb-order-x"), delete_op("mdrb-order-y")])

    assert resp.status == 200,
           "X and its one-way referrer Y, both deleted in the SAME batch, must succeed " <>
             "regardless of order -- they vanish together in one transaction: " <>
             "#{resp.status} #{resp.resp_body}"

    assert Content.get_document("mdrb-order-x", "post", @dataset, []) == {:error, :not_found}
    assert Content.get_document("mdrb-order-y", "post", @dataset, []) == {:error, :not_found}
  end

  test "a LONE delete mixed into a batch with creates still blocks on its referrer -- the single-id path is unaffected",
       %{conn: conn, slug: slug, raw: raw} do
    seed =
      mutate(conn, slug, raw, [
        create("mdrb-mixed-target"),
        create("mdrb-mixed-referrer", %{
          "author" => %{"_type" => "reference", "_ref" => "mdrb-mixed-target"}
        })
      ])

    assert seed.status == 200

    resp =
      mutate(conn, slug, raw, [
        create("mdrb-mixed-other"),
        delete_op("mdrb-mixed-target")
      ])

    assert resp.status == 409
    err = body(resp)["error"]
    assert err["code"] == "document_referenced"

    assert err["details"]["referrers"] == [
             %{"id" => "drafts.mdrb-mixed-referrer", "type" => "post"}
           ]
  end
end
