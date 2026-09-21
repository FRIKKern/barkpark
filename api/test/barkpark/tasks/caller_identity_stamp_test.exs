defmodule Barkpark.Tasks.CallerIdentityStampTest do
  @moduledoc """
  A task mutation names the identity the SERVER measured — not the one the
  audited client typed (task-56adb45f973e242f, criteria 1 and 2).

  ## The gap these arms close

  Every identity a task event carried was the audited party's own self-report:
  `content.claim.worker`, `closed_by` and `actor.worker` are all one free-form
  string the CLIENT chooses and the server stores verbatim. The server DID know
  better — `Internal.caller_stamp/1` has merged `caller_token_id` (the bearer it
  authenticated) since #16622-era — but that key is a member of
  `Internal.audit_keys/0`, and `Tasks.Events`' `:payload` projection is
  `document` MINUS `envelope_keys/0` MINUS `audit_keys/0`. So the one
  unfalsifiable identity on the row was subtracted by the only reader that
  could have shown it, on EVERY projection. Live measurement on guerrilla
  (2026-09-19, commit 38075b447) over `task-292729c36147a851`: the default
  projection is exactly `[at, doc_id, event, id, rev]` and the `--payload`
  projection adds `actor {worker, epoch}` + `session` — the client's string and
  a derived discriminator, and no server-measured principal anywhere.

  ## What is proven here

    * **criterion 1, reachability** — a claim, a close and a RELEASE driven
      through the real HTTP doors each put `payload.caller` on their event, and
      `GET /v1/tasks/events?doc_id=…&payload=true` returns it. Release is
      called out because it threaded NO server identity at all before this
      change — not even the audit key.
    * **criterion 1, unforgeability** — the request names `worker_id` and a
      session KEY of the client's choosing; `caller.id` is the api_token uuid
      the server authenticated and `caller.session` is the HMAC derivation, so
      neither equals what the body asked for. The CONTROL is in the same arm:
      the self-reported `actor.worker` on the SAME event IS the client's string,
      so the arm measures a difference between two fields of one row rather
      than asserting one field in isolation.
    * **criterion 2, no backfill** — an internal caller that names no token
      emits NO `caller` key. Not `%{}`, not `""`. A reader that finds no
      `caller` is reading UNMEASURED, which is the distinction an
      empty-string backfill would destroy across the whole back catalogue.
    * **the projection contract** — `caller` is NOT an audit key (so it
      projects) while `caller_token_id` still IS (so it does not), and the
      default no-payload wire shape is byte-identical.

  ## Mutation proof

  See the PR body for the pasted red from reverting the
  `caller_identity_stamp/2` merge inside `Internal.caller_stamp/2`.
  """

  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]

  alias Barkpark.{Auth, Content, Repo, Tasks, TenancyFixtures}
  alias Barkpark.Content.MutationEvent
  alias Barkpark.Tasks.{Claim, Events, Internal, SessionId}

  @token "barkpark-test-caller-identity-token"
  @dataset "production"
  @artifact "landed #19999 @ 63b89bef30 — the event names the server's caller"
  @session_key "client-chosen-session-key-abcdef"

  setup do
    {:ok, token} =
      Auth.create_token(@token, "test-caller-identity", "test", ["read", "write", "admin"])

    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope, token_id: token.id}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  # Every agent shares ONE test database and a page is 500 events, so replaying
  # from 0 would page our own rows off the front.
  defp baseline, do: Repo.one(from(e in MutationEvent, select: max(e.id))) || 0

  defp task!(scope, prefix \\ "caller-identity") do
    doc_id = uniq(prefix)

    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "acceptance_criteria" => [
              %{
                "criterion" => "the fixture states its bar",
                "met" => true,
                "evidence" => "stated in the fixture"
              }
            ]
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp authed(conn) do
    conn
    |> put_req_header("authorization", "Bearer " <> @token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("x-barkpark-session", @session_key)
  end

  defp rows_for(since, doc_id, event) do
    @dataset
    |> Events.replay_since(since, payload: true, limit: 500, doc_id: doc_id)
    |> Enum.filter(&(&1.event == event))
  end

  # ─── criterion 1 — the identity reaches a read surface ───────────────────

  describe "criterion 1 — every mutation door stamps a server caller" do
    test "claim / close / release each carry payload.caller over HTTP",
         %{conn: conn, scope: scope, token_id: token_id} do
      for {label, doc, drive, event} <- [
            {"claim", task!(scope), :claim, "task.claimed"},
            {"close", task!(scope), :close, "task.closed"},
            {"release", task!(scope), :release, "task.released"}
          ] do
        worker = uniq("worker")

        # Claim first for the doors that need a held lease.
        epoch =
          if drive in [:close, :release] do
            {:ok, claimed} = Claim.claim_by_id(doc.doc_id, worker, scope)
            get_in(claimed.content, ["claim", "epoch"])
          end

        since = baseline()

        resp =
          case drive do
            :claim ->
              conn
              |> authed()
              |> post("/v1/tasks/#{doc.doc_id}/claim", %{"worker_id" => worker})

            :close ->
              conn
              |> authed()
              |> post("/v1/tasks/#{doc.doc_id}/close", %{
                "worker_id" => worker,
                "observed_epoch" => epoch,
                "reason" => @artifact
              })

            :release ->
              conn
              |> authed()
              |> post("/v1/tasks/#{doc.doc_id}/release", %{
                "worker_id" => worker,
                "observed_epoch" => epoch
              })
          end

        # THE PRECONDITION, ASSERTED BEFORE THE SUBJECT. A refused door writes
        # no event, and "no event" would otherwise read as "no caller" — the
        # failure that makes an absent-attribution arm pass vacuously.
        assert json_response(resp, 200)["ok"] == true,
               "#{label} door refused: #{inspect(json_response(resp, 200))}"

        # BOUND FIRST, then asserted on a boolean. `assert [row] = expr, msg`
        # raises MatchError before assert/2 ever renders the message, so the
        # message would be dead text naming the door — the one thing this arm
        # needs said when a door silently writes nothing.
        rows = rows_for(since, doc.doc_id, event)

        assert length(rows) == 1,
               "#{label} wrote #{length(rows)} #{event} events, expected exactly 1"

        [row] = rows

        caller = get_in(row, [:payload, "caller"])

        assert is_map(caller),
               "#{label}: #{event} names no server caller: #{inspect(Map.get(row, :payload))}"

        assert caller["kind"] == "api_token"
        assert caller["id"] == token_id
        assert is_binary(caller["session"]) and caller["session"] != ""
      end
    end

    test "GET /v1/tasks/events?payload=true returns the caller to a reader",
         %{conn: conn, scope: scope, token_id: token_id} do
      doc = task!(scope)
      worker = uniq("worker")
      since = baseline()

      assert conn
             |> authed()
             |> post("/v1/tasks/#{doc.doc_id}/claim", %{"worker_id" => worker})
             |> json_response(200)
             |> Map.get("ok") == true

      body =
        conn
        |> authed()
        |> get("/v1/tasks/events", %{
          "doc_id" => doc.doc_id,
          "since" => to_string(since),
          "payload" => "true",
          "limit" => "500"
        })
        |> json_response(200)

      claimed = Enum.find(body["events"], &(&1["event"] == "task.claimed"))

      assert is_map(claimed), "the HTTP feed carried no task.claimed for the row we just claimed"

      assert get_in(claimed, ["payload", "caller", "id"]) == token_id,
             "the wire payload names no server caller: #{inspect(claimed["payload"])}"

      # THE AUDIT KEY IS STILL SUBTRACTED. `caller` projects BECAUSE it is not
      # an audit key; if both appeared, the projection contract would be the
      # thing that broke, not the thing that carried this.
      refute Map.has_key?(claimed["payload"], "caller_token_id")
    end

    test "the caller is not the string the client typed", %{conn: conn, scope: scope} do
      doc = task!(scope)
      since = baseline()

      assert conn
             |> authed()
             |> post("/v1/tasks/#{doc.doc_id}/claim", %{"worker_id" => "impostor-lead"})
             |> json_response(200)
             |> Map.get("ok") == true

      assert [row] = rows_for(since, doc.doc_id, "task.claimed")

      # THE CONTROL, ON THE SAME ROW: the self-report IS the client's string.
      # Without it, `caller.id != "impostor-lead"` would also pass on an event
      # that carried no client string at all.
      assert get_in(row, [:payload, "actor", "worker"]) == "impostor-lead"

      caller = get_in(row, [:payload, "caller"])
      assert is_map(caller)
      refute caller["id"] == "impostor-lead"
      refute caller["label"] == "impostor-lead"

      # The session is the HMAC derivation of the presented key, never the key.
      refute caller["session"] == @session_key
      assert caller["session"] == SessionId.derive(@session_key, caller["id"])
    end
  end

  # ─── criterion 2 — absence stays absence ─────────────────────────────────

  describe "criterion 2 — an unattributed mutation stays UNMEASURED" do
    test "an internal caller with no token emits NO caller key", %{scope: scope} do
      doc = task!(scope)
      since = baseline()

      # The domain door with no HTTP conn behind it — the shape every
      # pre-change row and every background writer has.
      {:ok, _} = Claim.claim_by_id(doc.doc_id, uniq("internal-worker"), scope)

      assert [row] = rows_for(since, doc.doc_id, "task.claimed")

      payload = Map.get(row, :payload) || %{}

      refute Map.has_key?(payload, "caller"),
             "a tokenless mutation manufactured an identity: #{inspect(payload["caller"])}"
    end

    test "caller_identity_stamp/2 never emits an empty placeholder" do
      # Not `%{"caller" => %{}}` and not `%{"caller" => ""}` — the ONLY honest
      # answer for a caller the server did not measure is no key.
      assert Internal.caller_identity_stamp(nil, nil) == %{}
      assert Internal.caller_identity_stamp(nil, "") == %{}
      assert Internal.caller_identity_stamp("", nil) == %{}

      # A session with no token is still a measurement, and it is kept.
      assert %{"caller" => %{"session" => "s_deadbeef"}} =
               Internal.caller_identity_stamp(nil, "s_deadbeef")

      # And the full shape carries all three, with the token as BOTH kind and id.
      assert %{"caller" => %{"kind" => "api_token", "id" => "tok-1", "session" => "s_1"}} =
               Internal.caller_identity_stamp("tok-1", "s_1")
    end

    test "caller is projected, caller_token_id is not — and the audit list says so" do
      assert "caller_token_id" in Internal.audit_keys()

      refute "caller" in Internal.audit_keys(),
             "putting `caller` in audit_keys/0 reproduces the exact defect this closes"

      refute "caller" in Internal.envelope_keys()
    end

    test "the default (no payload) wire shape is unchanged", %{conn: conn, scope: scope} do
      doc = task!(scope)
      since = baseline()

      assert conn
             |> authed()
             |> post("/v1/tasks/#{doc.doc_id}/claim", %{"worker_id" => uniq("worker")})
             |> json_response(200)
             |> Map.get("ok") == true

      body =
        conn
        |> authed()
        |> get("/v1/tasks/events", %{
          "doc_id" => doc.doc_id,
          "since" => to_string(since),
          "limit" => "500"
        })
        |> json_response(200)

      assert body["events"] != []

      for ev <- body["events"] do
        assert Enum.sort(Map.keys(ev)) == ~w(at doc_id event id rev)
      end
    end
  end
end
