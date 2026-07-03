defmodule BarkparkWeb.TicketsControllerTest do
  @moduledoc """
  Unit tests for the Tickets HTTP surface (charter Decisions 2, 3, 5).

  In THIS worktree the `/v1/tickets` routes mount only once the sibling auth
  slice adds the `:ticket_key` bucket and the plugin is enabled, so we exercise
  the controller by invoking its actions DIRECTLY with a hand-built conn:

    * submitter actions get `assign(:ticket_key, key)`
    * operator actions get the tenancy-scope assigns (`current_workspace`) +
      an `:api_token` whose label becomes the operator author name.

  This tests the controller LOGIC (identity-from-credential, derived status,
  fail-closed scoping, triage rows) independent of the router wiring the auth
  slice owns.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Repo
  alias BarkparkWeb.TicketsController
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    ws = TenancyFixtures.create_workspace!()
    scope = [workspace_id: ws.id]
    register_ticket_schema!(scope)
    key = mk_key(ws, "Kari")
    %{ws: ws, scope: scope, key: key}
  end

  defp mk_key(ws, name) do
    %{
      id: "key-#{System.unique_integer([:positive])}",
      name: name,
      workspace_id: ws.id,
      dataset: @dataset
    }
  end

  defp register_ticket_schema!(scope) do
    for schema_def <- Barkpark.Plugins.Tickets.register_schemas([]) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp submitter_conn(key), do: assign(build_conn(), :ticket_key, key)

  defp operator_conn(ws, label \\ "Support Desk") do
    build_conn()
    |> assign(:current_workspace, ws)
    |> assign(:api_token, %{label: label})
  end

  # File a ticket via the controller and return the created ticket's id + conn.
  defp file_ticket(key, subject \\ "Login broken", body \\ "help") do
    conn = TicketsController.create(submitter_conn(key), %{"subject" => subject, "body" => body})
    body = json_response(conn, 201)
    body["ticket"]["id"]
  end

  # ── Submitter: create ────────────────────────────────────────────────────

  describe "create/2 (submitter)" do
    test "files a ticket: 201, open, one submitter message stamped from the key", %{key: key} do
      conn =
        TicketsController.create(submitter_conn(key), %{
          "subject" => "Login broken",
          "body" => "I can't sign in"
        })

      body = json_response(conn, 201)
      assert body["ok"] == true
      ticket = body["ticket"]
      assert ticket["status"] == "open"
      assert ticket["key_name"] == "Kari"
      assert [msg] = ticket["messages"]
      assert msg["author_kind"] == "submitter"
      assert msg["author_name"] == "Kari"
      assert msg["body"] == "I can't sign in"
    end

    test "401 without a ticket key", %{} do
      conn = TicketsController.create(build_conn(), %{"subject" => "x", "body" => "y"})
      assert json_response(conn, 401)["reason"] == "unauthorized"
    end

    test "400 on a missing subject", %{key: key} do
      conn = TicketsController.create(submitter_conn(key), %{"body" => "y"})
      assert json_response(conn, 400)["reason"] == "bad_request"
    end
  end

  # ── Submitter: index_own (fail-closed scoping) ───────────────────────────

  describe "index_own/2 (submitter)" do
    test "lists only the calling key's tickets", %{ws: ws, key: key} do
      _a = file_ticket(key, "a")
      _b = file_ticket(key, "b")

      other = mk_key(ws, "Mallory")
      _c = file_ticket(other, "c")

      conn = TicketsController.index_own(submitter_conn(key), %{})
      body = json_response(conn, 200)
      subjects = body["tickets"] |> Enum.map(& &1["subject"]) |> Enum.sort()
      assert subjects == ["a", "b"]
      # list rows are lean — no full thread
      refute Map.has_key?(hd(body["tickets"]), "messages")
    end
  end

  # ── Submitter: show_own stamps the delivery signal ───────────────────────

  describe "show_own/2 (submitter)" do
    test "reading an answered ticket stamps submitter_seen_at", %{ws: ws, key: key} do
      id = file_ticket(key)
      # operator answers
      TicketsController.answer(operator_conn(ws), %{"id" => id, "body" => "try again"})

      conn = TicketsController.show_own(submitter_conn(key), %{"id" => id})
      body = json_response(conn, 200)
      assert body["ticket"]["status"] == "answered"
      assert is_binary(body["ticket"]["submitter_seen_at"])
    end

    test "a foreign key gets 404 (existence not leaked)", %{ws: ws, key: key} do
      id = file_ticket(key)
      other = mk_key(ws, "Mallory")

      conn = TicketsController.show_own(submitter_conn(other), %{"id" => id})
      assert json_response(conn, 404)["reason"] == "not_found"
    end
  end

  # ── Submitter: reply auto-reopens ────────────────────────────────────────

  describe "reply/2 (submitter)" do
    test "a reply on an answered ticket auto-reopens it", %{ws: ws, key: key} do
      id = file_ticket(key)
      TicketsController.answer(operator_conn(ws), %{"id" => id, "body" => "answer"})

      conn =
        TicketsController.reply(submitter_conn(key), %{"id" => id, "body" => "still broken"})

      body = json_response(conn, 200)
      assert body["ticket"]["status"] == "open"
      assert length(body["ticket"]["messages"]) == 3
    end

    test "ticket.reopened is emitted only for an ACTUAL reopen, not for a reply on an open ticket",
         %{ws: ws, key: key} do
      id = file_ticket(key)

      # Reply while still open — nothing reopened, no semantic event.
      TicketsController.reply(submitter_conn(key), %{"id" => id, "body" => "more info"})
      assert reopened_events() == 0

      # Answer, then reply — THAT is a reopen.
      TicketsController.answer(operator_conn(ws), %{"id" => id, "body" => "answer"})
      TicketsController.reply(submitter_conn(key), %{"id" => id, "body" => "still broken"})
      assert reopened_events() == 1
    end

    test "an oversized reply body maps to a clear 422 without leaking internals", %{key: key} do
      id = file_ticket(key)

      conn =
        TicketsController.reply(submitter_conn(key), %{
          "id" => id,
          "body" => String.duplicate("b", 65_537)
        })

      body = json_response(conn, 422)
      assert body["reason"] == "body_too_long"
      assert body["message"] =~ "too long"
    end
  end

  defp reopened_events do
    Repo.aggregate(from(e in MutationEvent, where: e.mutation == "ticket.reopened"), :count)
  end

  # ── Operator: inbox triage ───────────────────────────────────────────────

  describe "inbox/2 (operator)" do
    test "orders open-first and carries the triage row fields", %{ws: ws, key: key} do
      # one answered ticket, one open ticket — open must sort first
      answered_id = file_ticket(key, "answered-one")
      TicketsController.answer(operator_conn(ws), %{"id" => answered_id, "body" => "done"})
      _open_id = file_ticket(key, "open-one")

      conn = TicketsController.inbox(operator_conn(ws), %{})
      body = json_response(conn, 200)
      rows = body["tickets"]

      assert Enum.map(rows, & &1["subject"]) == ["open-one", "answered-one"]

      row = hd(rows)
      assert row["key_name"] == "Kari"
      assert row["status"] == "open"
      assert is_integer(row["waiting_age_seconds"])
      assert Map.has_key?(row, "message_count")
      assert Map.has_key?(row, "has_attachments")
      assert Map.has_key?(row, "seen")

      # The answered row must NOT carry a stale waiting age — it is waiting on
      # the submitter, not the operator.
      answered_row = Enum.find(rows, &(&1["status"] == "answered"))
      assert answered_row["waiting_age_seconds"] == nil
    end
  end

  # ── Operator: answer / close ─────────────────────────────────────────────

  describe "answer/2 + close/2 (operator)" do
    test "answer flips to answered and stamps the operator token label", %{ws: ws, key: key} do
      id = file_ticket(key)

      conn =
        TicketsController.answer(operator_conn(ws, "Desk-7"), %{"id" => id, "body" => "here"})

      body = json_response(conn, 200)
      assert body["ticket"]["status"] == "answered"
      last = List.last(body["ticket"]["messages"])
      assert last["author_kind"] == "operator"
      assert last["author_name"] == "Desk-7"
    end

    test "answer with close:true chains a close", %{ws: ws, key: key} do
      id = file_ticket(key)

      conn =
        TicketsController.answer(operator_conn(ws), %{
          "id" => id,
          "body" => "final answer",
          "close" => true
        })

      assert json_response(conn, 200)["ticket"]["status"] == "closed"
    end

    test "close flips to closed", %{ws: ws, key: key} do
      id = file_ticket(key)
      conn = TicketsController.close(operator_conn(ws), %{"id" => id})
      assert json_response(conn, 200)["ticket"]["status"] == "closed"
    end

    test "operator answer on a missing ticket is 404", %{ws: ws} do
      conn = TicketsController.answer(operator_conn(ws), %{"id" => "ticket-nope", "body" => "x"})
      assert json_response(conn, 404)["reason"] == "not_found"
    end
  end
end
