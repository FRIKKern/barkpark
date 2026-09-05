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
  use BarkparkWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
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

  # ── PDS w36 crit 2: render_ticket/3's receipt against the STORED ROW ─────
  #
  # `tickets_controller.ex:263` (`render_ticket/3`) is the ONE renderer every
  # ticket receipt passes through — create's 201, show_own, reply, answer and
  # close all end there. Every other test in this file reads that receipt and
  # NOTHING else, so a create that renders a faithful ticket while persisting
  # something different passes all of them. This is the differential: drive the
  # action in this file's own direct-action style, then certify the printed
  # ticket against the row read DIRECTLY through `Repo` — never through the
  # list or show endpoint, which would share any bug the renderer has.
  describe "render_ticket/3 receipt vs the stored row (PDS w36 crit 2)" do
    test "the 201 ticket names a real row and reports that row's content faithfully",
         %{key: key} do
      conn =
        TicketsController.create(submitter_conn(key), %{
          "subject" => "Receipt must match the row",
          "body" => "the printed thread has to be the stored thread"
        })

      receipt = json_response(conn, 201)
      assert receipt["ok"] == true
      rendered = receipt["ticket"]

      # THE ID THE RECEIPT HANDED THE CALLER MUST NAME A ROW. Read by that id,
      # through Repo, scoped to the single document this call created (never a
      # whole-table read — many agents share this test database).
      stored =
        Repo.get_by!(Document,
          doc_id: Content.draft_id(rendered["id"]),
          type: "ticket",
          dataset: @dataset
        )

      # THE POST-CONDITION: every field the receipt printed is the stored one.
      assert stored.content["subject"] == rendered["subject"]
      assert stored.content["status"] == rendered["status"]
      assert stored.content["key_id"] == rendered["key_id"]
      assert stored.content["key_name"] == rendered["key_name"]
      assert stored.content["waiting_since"] == rendered["waiting_since"]
      assert stored.content["submitter_seen_at"] == rendered["submitter_seen_at"]

      assert [stored_msg] = stored.content["messages"]
      assert [rendered_msg] = rendered["messages"]
      assert stored_msg["author_kind"] == rendered_msg["author_kind"]
      assert stored_msg["author_name"] == rendered_msg["author_name"]
      assert stored_msg["body"] == rendered_msg["body"]

      # AND THE STORED VALUES ARE THE CREDENTIAL'S, so a receipt that merely
      # agrees with itself cannot pass: identity comes from the key, and the
      # subject/body came from the request.
      assert stored.content["key_name"] == key.name
      assert stored.content["key_id"] == key.id
      assert stored.content["subject"] == "Receipt must match the row"
      assert stored_msg["body"] == "the printed thread has to be the stored thread"
    end

    test "an operator answer's receipt matches the row the answer wrote", %{ws: ws, key: key} do
      id = file_ticket(key)

      conn =
        TicketsController.answer(operator_conn(ws, "Desk-9"), %{"id" => id, "body" => "fixed"})

      rendered = json_response(conn, 200)["ticket"]

      stored =
        Repo.get_by!(Document,
          doc_id: Content.draft_id(id),
          type: "ticket",
          dataset: @dataset
        )

      assert stored.content["status"] == rendered["status"]
      assert stored.content["status"] == "answered"
      assert length(stored.content["messages"]) == length(rendered["messages"])

      stored_last = List.last(stored.content["messages"])
      rendered_last = List.last(rendered["messages"])
      assert stored_last["author_kind"] == rendered_last["author_kind"]
      assert stored_last["author_name"] == rendered_last["author_name"]
      assert stored_last["body"] == rendered_last["body"]
      assert stored_last["author_name"] == "Desk-9"
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
