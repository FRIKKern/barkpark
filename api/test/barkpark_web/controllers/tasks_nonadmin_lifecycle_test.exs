defmodule BarkparkWeb.TasksNonadminLifecycleTest do
  @moduledoc """
  The task order lifecycle under a NON-admin bearer (task-pdf-bl-nonadmin-task-tests).

  `tasks_controller_test.exs` runs claim/pulse/close under `@token`, which
  carries `["read", "write", "admin"]`. Admin bypasses several judgments, so
  that file cannot tell "the route admits a member token" from "the route
  admits an admin". The MVP-0 offload data plane (PDF-D87) hands a fleet
  listener a MEMBER app token — `["read", "write"]`, or `["read", "write",
  "chat"]` for a chat-hosted worker — and the verdict that such a token can run
  a whole order rests on the route gates alone:

    * every `/v1/tasks/*` route is declared `auth: :token_root`
      (`Barkpark.Plugins.Tasks.register_routes/1`), which mounts on
      `pipe_through([:api, :require_token, RequireWriteForMutation])` — a token
      check plus a METHOD-derived write gate. No admin plug anywhere.
    * the order CREATE is `POST /v1/data/mutate/:dataset`, on
      `pipe_through([:api, :require_token, :require_write, :idempotent])` —
      `RequireWritePermission`, again no admin plug.

  This file pins that pair of facts end-to-end so a future `:require_admin` on
  either bucket reds here instead of silently bricking every fleet listener.

  Two shapes:

    * `c0` — a full create -> claim -> pulse -> close, green, under BOTH
      `["read", "write"]` and `["read", "write", "chat"]`, with the caller's
      stored permissions asserted admin-free and every hop asserted un-403'd.
    * `c1` — the `token_root` CONTRAST for a `["read"]` token: 403 at the
      write-scoped order create, 403 at the write-METHOD `POST /v1/tasks/claim`,
      and 200 at the safe-method reads on the very same bucket.

  Rate limiting is per-resolved-token (`BarkparkWeb.Plugs.RateLimit`) and every
  test here mints its own bearer, but the suite shares a server: each assertion
  goes through `arrived!/2`, which refuses a 429 as "the request never reached
  the gate" rather than letting it read as a verdict about permissions.
  """

  use BarkparkWeb.ConnCase, async: true

  alias Barkpark.{Auth, Content, Tasks, TenancyFixtures}
  alias Barkpark.Auth.ApiToken

  @dataset "production"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]
    register_schemas!(scope)
    %{scope: scope}
  end

  describe "c0 — full order lifecycle under a non-admin member token" do
    for {label, perms} <- [
          {"read+write", ["read", "write"]},
          {"read+write+chat", ["read", "write", "chat"]}
        ] do
      # `perms` is unquoted into the test body below; this silences the
      # comprehension-variable warning without hiding the binding.
      _ = perms

      test "create -> claim -> pulse -> close is green for a #{label} token, no admin gate",
           %{conn: conn} do
        token = mint_token!(unquote(perms))

        # Precondition, asserted rather than assumed: the credential this test
        # is about really lacks "admin". Without this the whole test could pass
        # on an admin bearer and prove nothing about the member tier.
        stored = token_permissions(token)
        assert "admin" not in stored, "the fixture token carries admin: #{inspect(stored)}"
        assert "write" in stored

        phase = uniq("nonadmin-phase")
        doc_id = uniq("nonadmin-order")

        # ── CREATE — the write-scoped bucket (:require_write), not token_root.
        create =
          conn
          |> authed(token)
          |> post(
            "/v1/data/mutate/#{@dataset}",
            Jason.encode!(%{
              "mutations" => [
                %{
                  "create" => %{
                    "_id" => doc_id,
                    "_type" => "task",
                    "title" => "non-admin lifecycle #{doc_id}",
                    "content" => %{
                      "kind" => "task",
                      "lifecycle_status" => "open",
                      "priority" => 2,
                      "parent_id" => phase,
                      # PDS-D291: a `done` close of a criteria-less kind:task row
                      # 409s `close_reason_needs_artifact`. One met criterion
                      # keeps this test measuring AUTHORIZATION.
                      "acceptance_criteria" => [
                        %{"criterion" => "the fixture is closeable", "met" => true}
                      ]
                    }
                  }
                }
              ]
            })
          )

        arrived!(create, "order create")
        assert create.status == 200, "a #{unquote(label)} token was refused the order create"
        assert [%{"id" => "drafts." <> ^doc_id}] = Jason.decode!(create.resp_body)["results"]

        # ── CLAIM — token_root, a POST, so RequireWriteForMutation must ADMIT
        #    a member's "write" without ever consulting "admin".
        claim =
          conn
          |> authed(token)
          |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "w-nonadmin", phase_id: phase}))

        arrived!(claim, "claim")
        assert claim.status == 200
        claim_payload = Jason.decode!(claim.resp_body)
        assert claim_payload["ok"] == true, "claim refused: #{claim.resp_body}"
        claimed = claim_payload["doc"]["doc_id"]
        assert claim_payload["doc"]["lifecycle_status"] == "in_progress"
        assert claim_payload["doc"]["claim"]["worker"] == "w-nonadmin"
        assert claim_payload["doc"]["claim"]["epoch"] == 1

        # ── PULSE — token_root POST. It BUMPS the claim epoch, so the close
        #    below must observe the epoch this response reports, not the claim's.
        pulse =
          conn
          |> authed(token)
          |> post(
            "/v1/tasks/#{claimed}/pulse",
            Jason.encode!(%{worker_id: "w-nonadmin", now: "halfway through the order"})
          )

        arrived!(pulse, "pulse")
        assert pulse.status == 200
        pulse_payload = Jason.decode!(pulse.resp_body)
        assert pulse_payload["ok"] == true, "pulse refused: #{pulse.resp_body}"
        epoch = pulse_payload["doc"]["claim"]["epoch"]
        assert epoch == 2, "pulse must bump the epoch; got #{inspect(epoch)}"

        # ── CLOSE — token_root POST, CAS on the epoch the pulse left behind.
        close =
          conn
          |> authed(token)
          |> post(
            "/v1/tasks/#{claimed}/close",
            Jason.encode!(%{worker_id: "w-nonadmin", observed_epoch: epoch})
          )

        arrived!(close, "close")
        assert close.status == 200
        close_payload = Jason.decode!(close.resp_body)
        assert close_payload["ok"] == true, "close refused: #{close.resp_body}"
        assert close_payload["doc"]["lifecycle_status"] == "done"

        # The whole point, said once more as a single claim: not one hop of the
        # lifecycle answered 403. A `:require_admin` on either bucket turns each
        # of these into a 403 and this line names which.
        for {name, resp} <- [
              {"create", create},
              {"claim", claim},
              {"pulse", pulse},
              {"close", close}
            ] do
          refute resp.status == 403, "#{name} 403'd a non-admin #{unquote(label)} token"
        end
      end
    end
  end

  describe "c1 — token_root contrast for a read-only token" do
    test "403 at the order create, 403 at POST claim, 200 at the ready/show READS",
         %{conn: conn, scope: scope} do
      read_only = mint_token!(["read"])

      stored = token_permissions(read_only)
      assert stored == ["read"], "the fixture token is not read-only: #{inspect(stored)}"

      # A row for the reads to find, seeded OUT OF BAND — the read-only token
      # is precisely the credential that cannot create one.
      phase = uniq("readonly-phase")
      doc_id = uniq("readonly-order")
      seed_task!(doc_id, phase, scope)

      # ── The write-scoped bucket: RequireWritePermission refuses.
      create =
        conn
        |> authed(read_only)
        |> post(
          "/v1/data/mutate/#{@dataset}",
          Jason.encode!(%{
            "mutations" => [
              %{
                "create" => %{
                  "_id" => uniq("readonly-create"),
                  "_type" => "task",
                  "title" => "read-only must not create an order",
                  "content" => %{"kind" => "task", "lifecycle_status" => "open"}
                }
              }
            ]
          })
        )

      arrived!(create, "read-only order create")

      assert create.status == 403,
             "a read-only token created an order (status #{create.status}): #{create.resp_body}"

      # ── SAME token_root bucket, contrast made explicit. The bucket carries NO
      #    per-route write gate; `RequireWriteForMutation` closes it by METHOD.
      #    So on one and the same pipeline:
      #      POST  -> delegated to RequireWritePermission -> 403 for "read"
      #      GET   -> safe method, passes untouched       -> 200 for "read"
      claim =
        conn
        |> authed(read_only)
        |> post("/v1/tasks/claim", Jason.encode!(%{worker_id: "w-ro", phase_id: phase}))

      arrived!(claim, "read-only claim")

      assert claim.status == 403,
             "a read-only token claimed on token_root (status #{claim.status}): #{claim.resp_body}"

      ready = conn |> authed(read_only) |> get("/v1/tasks/ready?phase_id=#{phase}")
      arrived!(ready, "read-only ready")

      assert ready.status == 200,
             "the READ half of token_root refused a read-only token: #{ready.resp_body}"

      ready_ids = Enum.map(Jason.decode!(ready.resp_body)["docs"] || [], & &1["doc_id"])

      assert Enum.any?(ready_ids, &String.ends_with?(&1, doc_id)),
             "ready answered 200 but without the seeded row — the read proved nothing " <>
               "(saw #{inspect(ready_ids)})"

      show = conn |> authed(read_only) |> get("/v1/tasks/#{doc_id}")
      arrived!(show, "read-only show")

      assert show.status == 200,
             "GET /v1/tasks/:doc_id refused a read-only token: #{show.resp_body}"

      # The row is a DRAFT (`Content.Writer.create_document` forces every birth
      # through `DraftId.draft_id/1`), so the read echoes `drafts.<id>` — the
      # point of this assertion is that the READ RETURNED THE SEEDED ROW, not
      # an empty envelope with a 200 on it.
      assert String.ends_with?(Jason.decode!(show.resp_body)["doc"]["doc_id"], doc_id)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────

  # A 429 is the shared suite's rate limiter, never a verdict about
  # permissions. Assert the request ARRIVED at the gate before reading its
  # status as an answer.
  defp arrived!(resp, what) do
    refute resp.status == 429,
           "#{what} was rate-limited (429) — the request never reached the auth gate, so " <>
             "nothing below it measures anything. Re-run; if it persists, the suite is " <>
             "sharing a bearer bucket."

    resp
  end

  defp mint_token!(permissions) do
    raw = "barkpark-test-nonadmin-#{System.unique_integer([:positive])}"
    {:ok, _} = Auth.create_token(raw, "test-nonadmin-lifecycle", "test", permissions)
    raw
  end

  defp token_permissions(raw) do
    Barkpark.Repo.get_by!(ApiToken, token_hash: ApiToken.hash_token(raw)).permissions
  end

  defp authed(conn, raw) do
    conn
    |> put_req_header("authorization", "Bearer " <> raw)
    |> put_req_header("content-type", "application/json")
  end

  defp seed_task!(doc_id, phase, scope) do
    {:ok, doc} =
      Content.create_document(
        "task",
        %{
          "doc_id" => doc_id,
          "title" => doc_id,
          "content" => %{
            "kind" => "task",
            "lifecycle_status" => "open",
            "parent_id" => phase,
            "acceptance_criteria" => [
              %{"criterion" => "the fixture is closeable", "met" => true}
            ]
          }
        },
        @dataset,
        scope
      )

    doc
  end

  defp register_schemas!(scope) do
    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
