defmodule Barkpark.Tasks.ClaimSessionDiscriminatorTest do
  @moduledoc """
  task-f79e39f4992749a5 — a worker id is LANE-scoped, so two sessions of one
  lane write an indistinguishable ledger.

  MEASURED across the 2026-09-06/07 campaign: every session of the cli lane
  claims, pulses, stamps and closes as `lead-cli`. A predecessor that wakes on
  an inbox message writes a row byte-identical to the live lead's, and
  `claim-health.sh` was STRUCTURALLY unable to separate them because the
  discriminator was never written down. `Tasks.Internal.caller_stamp/1` did not
  help twice over: on the claim path it was EVENT metadata only (0 of 13 claim
  objects carried it, so `bp task get` could never see it), and every lane
  session on the box authenticates with the SAME admin token, so where it IS
  stored it discriminates nothing.

  ## What these tests have to prove, and in which direction

  A stored field is easy to assert and easy to make vacuous. Four directions,
  all required:

    * POSITIVE — two DIFFERENT session keys under ONE worker id land under
      different `claim.session` values, readable from the stored row alone.
    * STABILITY — the SAME key read twice is the SAME id, or the field is
      noise and one session looks like many.
    * THE NEGATIVE ARM (criterion 0's, the load-bearing one) — presenting the
      STORED id as if it were the key does NOT reproduce that id. This is what
      makes the value non-replayable: a second session that reads a peer's row
      cannot write under the peer's identity.
    * BACKWARD COMPATIBILITY — a sessionless caller writes NO key. Not an empty
      string: the key itself must be absent, so every claim taken before this
      shipped and every pre-existing client stay byte-identical, and the reader
      reports them as unattributed rather than as a collision.

  And, throughout: THE SESSION IS ATTRIBUTION, NEVER A FENCE. The CAS is
  `worker + epoch` and is byte-unchanged — a pulse or a close presenting a
  different session (or none) is still accepted, which the last describe block
  proves directly, because making it a fence would orphan every live claim.
  """

  use Barkpark.DataCase, async: false

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Tasks.SessionId
  alias Barkpark.{Repo, Tasks}

  @dataset "production"
  @token "tok-shared-by-every-lane-session"

  setup do
    {ws, project} = Barkpark.TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id]

    for schema_def <- Tasks.schema_definitions(@dataset) do
      attrs =
        schema_def
        |> Map.from_struct()
        |> Map.drop([:__meta__, :id, :inserted_at, :updated_at])
        |> Map.new(fn {k, v} -> {to_string(k), v} end)

      {:ok, _} = Content.upsert_schema(attrs, @dataset, scope)
    end

    %{scope: scope}
  end

  defp uniq(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp mk!(scope, extra \\ %{}) do
    doc_id = uniq("csd")

    content =
      Map.merge(
        %{
          "kind" => "task",
          "lifecycle_status" => "open",
          "acceptance_criteria" => [
            %{"criterion" => "the sessions are separable", "met" => false, "evidence" => ""}
          ]
        },
        extra
      )

    {:ok, doc} =
      Content.create_document(
        "task",
        %{"doc_id" => doc_id, "title" => doc_id, "content" => content},
        @dataset,
        scope
      )

    doc
  end

  # THE STORED ROW, never the returned struct — the criterion says "readable by
  # reading the stored row alone".
  defp stored_claim(%Document{id: id}), do: Repo.get!(Document, id).content["claim"] || %{}

  describe "SessionId.derive/2 — the id itself" do
    test "two different keys derive two different ids, and one key is stable" do
      a1 = SessionId.derive("session-key-of-lead-cli-r4", @token)
      a2 = SessionId.derive("session-key-of-lead-cli-r4", @token)
      b = SessionId.derive("session-key-of-lead-cli-r2", @token)

      assert is_binary(a1) and String.starts_with?(a1, "s_")
      assert a1 == a2, "one session key derived two ids — its writes would look like two sessions"
      assert a1 != b, "two session keys derived ONE id — this is the lane collision, reproduced"
    end

    test "THE NEGATIVE ARM: the stored id is not the key, so it cannot be replayed" do
      key = "session-key-of-lead-cli-r4"
      stored = SessionId.derive(key, @token)

      # A second session reads `claim.session` off a row it can see and presents
      # it as its own key. It must NOT land under that id.
      replayed = SessionId.derive(stored, @token)

      assert replayed != stored,
             "presenting the stored id reproduced it — a peer's session is forgeable from the ledger"

      # And the control, so the inequality above is not just "derive returns
      # garbage": the real key still derives the real id in the same run.
      assert SessionId.derive(key, @token) == stored
    end

    test "an absent or blank key derives NOTHING, and the stamp omits the key entirely" do
      assert SessionId.derive(nil, @token) == nil
      assert SessionId.derive("", @token) == nil
      assert SessionId.derive("   ", @token) == nil
      assert SessionId.session_stamp(nil) == %{}
      assert SessionId.put_session(%{"worker" => "lead-cli"}, nil) == %{"worker" => "lead-cli"}
    end
  end

  describe "the stored claim carries the session" do
    test "two sessions of ONE worker id are separable from the stored rows alone", %{scope: scope} do
      s_r4 = SessionId.derive("key-r4", @token)
      s_r2 = SessionId.derive("key-r2", @token)

      doc_a = mk!(scope)
      doc_b = mk!(scope)

      {:ok, _} = Tasks.claim_by_id(doc_a.doc_id, "lead-cli", scope ++ [session: s_r4])
      {:ok, _} = Tasks.claim_by_id(doc_b.doc_id, "lead-cli", scope ++ [session: s_r2])

      a = stored_claim(doc_a)
      b = stored_claim(doc_b)

      # The pre-fix ledger: identical on the only fields it had.
      assert a["worker"] == b["worker"] and a["worker"] == "lead-cli"
      assert a["epoch"] == b["epoch"]

      # The fix: separable anyway.
      assert a["session"] == s_r4
      assert b["session"] == s_r2
      assert a["session"] != b["session"]
      assert a["session_origin"] == s_r4
      assert b["session_origin"] == s_r2
    end

    test "BACKWARD COMPATIBILITY: a sessionless claim carries NO session key at all",
         %{scope: scope} do
      doc = mk!(scope)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "lead-cli", scope)

      claim = stored_claim(doc)

      refute Map.has_key?(claim, "session"),
             "a sessionless caller wrote a session key — every pre-existing client and every " <>
               "live claim taken before this shipped would change shape"

      refute Map.has_key?(claim, "session_origin")

      # The control on the read: this IS the claim this call wrote.
      assert claim["worker"] == "lead-cli"
      assert claim["epoch"] == 1
    end

    test "a pulse by a DIFFERENT session of the same lane is ALLOWED and RECORDED",
         %{scope: scope} do
      origin = SessionId.derive("key-r2", @token)
      successor = SessionId.derive("key-r4", @token)

      doc = mk!(scope)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "lead-cli", scope ++ [session: origin])
      task = Repo.get!(Document, doc.id)

      # ATTRIBUTION, NOT A FENCE. The successor holds the same lane worker id,
      # so the pulse must SUCCEED — refusing it would orphan the live claim.
      {:ok, _} =
        Tasks.pulse_by_id(task.id, "lead-cli", text: "successor woke and wrote", session: successor)

      claim = stored_claim(doc)

      assert claim["session"] == successor, "the pulse's own session was not recorded"

      assert claim["session_origin"] == origin,
             "session_origin moved — the row can no longer say WHO took the lease"

      assert claim["session"] != claim["session_origin"],
             "this is the reported-collision signal claim-health.sh reads"

      # The now-line is the surface whose generation label proved unreliable
      # evidence; it is now backed by a field the writer could not choose.
      assert get_in(claim, ["now", "text"]) == "successor woke and wrote"
    end

    test "a close records the sealing session beside closed_by, leaving the claim's own intact",
         %{scope: scope} do
      origin = SessionId.derive("key-r2", @token)
      sealer = SessionId.derive("key-r4", @token)

      doc = mk!(scope)
      {:ok, _} = Tasks.claim_by_id(doc.doc_id, "lead-cli", scope ++ [session: origin])
      task = Repo.get!(Document, doc.id)
      epoch = stored_claim(doc)["epoch"]

      {:ok, _} =
        Tasks.close(task.id, "lead-cli",
          observed_epoch: epoch,
          # `cancelled` is exempt from the criteria gate BY NAME, which keeps
          # this test about the SESSION stamp and not about the criteria door.
          lifecycle_status: "cancelled",
          reason: "superseded — this row exists to exercise the close-side session stamp",
          session: sealer
        )

      claim = stored_claim(doc)

      assert claim["closed_by"] == "lead-cli"
      assert claim["closed_session"] == sealer
      assert claim["session_origin"] == origin

      refute claim["closed_session"] == claim["session_origin"],
             "the sealing session and the claiming session collapsed into one value"
    end
  end
end
