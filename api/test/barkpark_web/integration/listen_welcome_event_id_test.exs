defmodule BarkparkWeb.Integration.ListenWelcomeEventIdTest do
  @moduledoc """
  task-399143cf7ac6b952. Before this fix the welcome frame was a pure string
  literal carrying no `id:` line. A fresh client (no prior Last-Event-ID) that
  disconnected before any LIVE event arrived had nothing to resume from: its
  next connection opened with no `lastEventId`, so `listen/2`'s `if since do`
  replay branch never ran at all, and every event written in the gap was
  silently lost — not delayed, GONE, because no replay request was ever made
  for it.

  These assert the fix end-to-end through the real HTTP door: the welcome
  frame now carries `id: <head event id>`, and reconnecting with THAT id (not
  a client-invented one) replays exactly, and only, the events written after
  it — mirrors the stronger claim `EventLog.head_event_id/3`'s own unit tests
  prove at the domain layer (same file naming convention,
  test/barkpark/content/event_log_test.exs).
  """
  use BarkparkWeb.ConnCase, async: false

  import Barkpark.TenancyFixtures

  alias Barkpark.{Auth, Content, Tenancy}

  @type_name "post"

  setup do
    ws = create_workspace!("listen-welcome-#{System.unique_integer([:positive])}")
    proj = create_project!(ws)
    ds = "listen-welcome-ds-#{System.unique_integer([:positive])}"
    {:ok, _} = Tenancy.get_or_create_dataset(proj, ds)

    raw = "listen-welcome-" <> Ecto.UUID.generate()
    {:ok, _} = Auth.create_token(raw, "listen-welcome-member", ds, ["read"], ws.id)

    {:ok, ws: ws, proj: proj, ds: ds, raw: raw}
  end

  # Opens the stream, ends it immediately (the same :sse_overloaded trick
  # listen_project_scope_test.exs uses — no real flood needed, just a signal
  # the loop already reacts to), and returns the buffered body.
  defp open_and_capture(ctx, params) do
    conn = put_req_header(ctx.conn, "authorization", "Bearer " <> ctx.raw)
    path = "/w/#{ctx.ws.slug}/p/#{ctx.proj.slug}/v1/data/listen/#{ctx.ds}"
    task = Task.async(fn -> get(conn, path, params) end)
    send(task.pid, :sse_overloaded)
    conn = Task.await(task, 20_000)
    assert conn.status == 200
    conn.resp_body
  end

  defp welcome_id(body) do
    case Regex.run(~r/^id: (\d+)\nevent: welcome\n/m, body) do
      [_, id] -> String.to_integer(id)
      nil -> nil
    end
  end

  test "an empty dataset's welcome frame carries no id: line", ctx do
    body = open_and_capture(ctx, %{})
    assert body =~ "event: welcome"
    refute body =~ ~r/^id: \d+\nevent: welcome\n/m
  end

  test "the welcome frame's id is the dataset's actual head event id", ctx do
    {:ok, doc} = create_document_in!(ctx.ws, ctx.proj, @type_name, %{"title" => "one"}, ctx.ds)

    body = open_and_capture(ctx, %{})
    head = welcome_id(body)

    assert is_integer(head)

    [event] =
      Content.EventLog.replay_since(ctx.ds, head - 1, ctx.ws.id, project_id: ctx.proj.id)
      |> Enum.to_list()

    assert event.doc_id == doc.doc_id,
           "the welcome frame's id did not name the document just written"
  end

  test "reconnecting with the welcome frame's id replays only what was written after it", ctx do
    {:ok, _first} = create_document_in!(ctx.ws, ctx.proj, @type_name, %{"title" => "one"}, ctx.ds)

    head = welcome_id(open_and_capture(ctx, %{}))
    assert is_integer(head)

    {:ok, second} =
      create_document_in!(ctx.ws, ctx.proj, @type_name, %{"title" => "two"}, ctx.ds)

    body = open_and_capture(ctx, %{"lastEventId" => Integer.to_string(head)})

    assert body =~ second.doc_id, "the second document must be replayed"
    refute body =~ "\"title\":\"one\"", "the FIRST document must not be replayed again"
  end
end
