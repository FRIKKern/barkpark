defmodule BarkparkWeb.Integration.ListenProjectScopeTest do
  @moduledoc """
  Realtime authz sweep (r4a): the listen stream leaked a SIBLING PROJECT's
  private fields.

  The stream subscribes to `documents:ws:<ws>:<dataset>` and replays
  `mutation_events` filtered by workspace — both shared by every project in the
  workspace that has a dataset of the same name (every project gets
  `production`). Each event is re-rendered through `Content.get_document/4`
  scoped to the LISTENER's project; an event from project P2 misses there, and
  the miss fell back to `Envelope.redact(event.document, schema)` with P1's
  schema for the type — usually none — so P2's private fields went out in
  clear to a P1 listener, replay and live.

  The fix drops an event whose project is not the listener's project.
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tenancy}

  @ds "production"
  @type_name "staffRecord"

  setup do
    ws = create_workspace!("listen-proj-#{System.unique_integer([:positive])}")
    p1 = create_project!(ws, "p-one")
    p2 = create_project!(ws, "p-two")
    for p <- [p1, p2], do: {:ok, _} = Tenancy.get_or_create_dataset(p, @ds)

    # The private field is declared ONLY in P2 — P1 has no schema for the type.
    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => @type_name,
          "title" => "Staff",
          "visibility" => "private",
          "fields" => [
            %{"name" => "title", "type" => "string"},
            %{"name" => "salary", "type" => "string", "private" => true}
          ]
        },
        @ds,
        workspace_id: ws.id,
        project_id: p2.id
      )

    {:ok, doc} =
      create_document_in!(
        ws,
        p2,
        @type_name,
        %{"title" => "P2 staff", "salary" => "SECRET-SALARY-99"},
        @ds
      )

    raw = "listen-proj-member-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "listen-proj-member", @ds, ["read"], ws.id)

    {:ok, ws: ws, p1: p1, p2: p2, doc: doc, raw: raw}
  end

  defp replay_body(conn, raw, ws, proj) do
    conn = put_req_header(conn, "authorization", "Bearer " <> raw)
    path = "/w/#{ws.slug}/p/#{proj.slug}/v1/data/listen/#{@ds}"
    task = Task.async(fn -> get(conn, path, %{"lastEventId" => "0"}) end)
    send(task.pid, :sse_overloaded)
    conn = Task.await(task, 20_000)
    assert conn.status == 200
    conn.resp_body
  end

  test "a P1 listener receives nothing of P2's private field", ctx do
    body = replay_body(ctx.conn, ctx.raw, ctx.ws, ctx.p1)
    assert body =~ "event: welcome"

    refute body =~ "SECRET-SALARY-99",
           "the P1 listen stream replayed a sibling project's private field"
  end

  test "a P2 listener still receives P2's document, with the private field redacted (control)",
       ctx do
    body = replay_body(ctx.conn, ctx.raw, ctx.ws, ctx.p2)
    assert body =~ ctx.doc.doc_id
    refute body =~ "SECRET-SALARY-99"
  end
end
