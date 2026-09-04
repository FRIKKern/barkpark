defmodule Barkpark.Content.WriterConnectionFaultTest do
  @moduledoc """
  task-a0ce4e18f6776400 — "a pool-exhaustion `DBConnection.ConnectionError` on
  the task create path is classified NOWHERE".

  `Tasks.Dedup.fetch_candidates/2` renders a pool fault as a NAMED, retryable
  503, and its own comment says the guard is on the wrong side of the boundary:
  "That DBConnection.ConnectionError is raised OUTSIDE this function, so the
  rescue/catch below never see it." Every other Repo call on the create path —
  the `Content.get_document` prev-doc lookup, the four birth guards, and the
  `Repo.insert` in `create_after_dedup/6` — sat outside it, so a dropped
  checkout surfaced as 500 `internal_error / "unknown error
  (DBConnection.ConnectionError)"`: a TERMINAL shape for a TRANSIENT fault, on
  the code `BarkparkCloud.Sites.Deploy.transient_refusal?/1` refuses retry grace
  to.

  Four properties, each of which can FAIL:

    * **THE RAISE SITE IS NAMED** — the fault is injected at two SPECIFIC Repo
      call sites (`:prev_doc_lookup`, `:insert`) via the test-only seam
      `Writer.inject_write_fault!/1`, and what is asserted is the RESPONSE
      SHAPE, never elapsed time.
    * **THE ERROR IS NAMED AND RETRYABLE** — 503 `storage_unavailable` with
      `reason: "connection_unavailable"`, not 500 `internal_error`.
    * **THE AMBIGUITY IS STATED** — the message says the draft row may already
      have landed and names `bp doc ls task --perspective drafts`.
    * **NO NEW FAIL-OPEN, AND A BOUNDED BLAST RADIUS** — a NON-connection
      exception at the identical site still propagates untouched, the rescue
      never manufactures an `{:ok, _}` or an empty result, and the untouched
      `upsert_document/4` door still raises the very exception the create door
      now names.

  `async: false`: the fault seam is `Application.put_env`, which is global.
  """
  use Barkpark.DataCase, async: false

  import ExUnit.CaptureLog, only: [with_log: 1]

  alias Barkpark.{Content, Tasks, TenancyFixtures}
  alias Barkpark.Content.Errors

  @dataset "production"
  @fault_message "tcp recv: closed"

  setup do
    {ws, project} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: project.id, source: :api]
    register_schemas!(scope)
    on_exit(fn -> Application.delete_env(:barkpark, :writer_fault) end)
    %{scope: scope}
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

  defp task_attrs(doc_id),
    do: %{
      "doc_id" => doc_id,
      "title" => doc_id,
      "content" => %{"kind" => "task", "lifecycle_status" => "open"}
    }

  defp arm!(site, module \\ DBConnection.ConnectionError, message \\ @fault_message) do
    Application.put_env(:barkpark, :writer_fault, {site, module, message})
  end

  defp create(doc_id, scope),
    do: Content.create_document("task", task_attrs(doc_id), @dataset, scope)

  # ── THE RAISE SITE IS NAMED, AND THE ANSWER IS A NAMED RETRYABLE 503 ───────

  describe "a DBConnection.ConnectionError on the create path" do
    for site <- [:prev_doc_lookup, :insert] do
      test "at the #{site} Repo call answers 503 storage_unavailable/connection_unavailable",
           %{scope: scope} do
        site = unquote(site)
        arm!(site)
        doc_id = uniq("dbconn-#{site}")

        {result, log} = with_log(fn -> create(doc_id, scope) end)
        assert log =~ "the database connection was lost mid-write"

        # The RESPONSE SHAPE — not elapsed time.
        assert {:error, {:connection_unavailable, message}} = result

        env = Errors.to_envelope(result)
        assert env.status == 503
        assert env.code == "storage_unavailable"
        assert env.reason == "connection_unavailable"

        # NOT the pre-fix answer.
        refute env.code == "internal_error"
        refute env.message =~ "unknown error"

        # The exception's own text survives, so an operator can tell a checkout
        # timeout from a closed socket without reading the server log.
        assert message =~ @fault_message
        assert env.message =~ @fault_message
      end
    end

    test "the refusal STATES THE AMBIGUITY and names how to check for the debris",
         %{scope: scope} do
      arm!(:insert)

      {{:error, {:connection_unavailable, message}}, _log} =
        with_log(fn -> create(uniq("dbconn-ambiguity"), scope) end)

      # A blind "resend the identical request" walks the caller into the dedup
      # wall on debris the first attempt left. The refusal must say so.
      assert message =~ "AMBIGUOUS"
      assert message =~ "may already have landed"
      assert message =~ "bp doc ls task --perspective drafts"
      assert message =~ "resend the identical request"

      env = Errors.to_envelope({:error, {:connection_unavailable, message}})
      assert env.hint =~ "CHECK WHETHER IT LANDED before retrying"
      assert env.hint =~ "bp doc ls task --perspective drafts"
    end
  end

  # ── NO NEW FAIL-OPEN ───────────────────────────────────────────────────────

  describe "the rescue is narrow" do
    test "a NON-connection exception at the SAME site still propagates untouched",
         %{scope: scope} do
      arm!(:prev_doc_lookup, RuntimeError, "not a connection fault")

      assert_raise RuntimeError, "not a connection fault", fn ->
        create(uniq("dbconn-nonconn"), scope)
      end

      # And at the insert site too — the rescue covers a REGION, so it is the
      # region's whole surface that must stay honest, not one call.
      arm!(:insert, ArgumentError, "also not a connection fault")

      assert_raise ArgumentError, "also not a connection fault", fn ->
        create(uniq("dbconn-nonconn-insert"), scope)
      end
    end

    test "the rescue never manufactures a success, and NOTHING is written",
         %{scope: scope} do
      arm!(:insert)
      doc_id = uniq("dbconn-no-fail-open")

      {result, _log} = with_log(fn -> create(doc_id, scope) end)

      refute match?({:ok, _}, result)
      refute match?(:ok, result)
      refute match?({:error, nil}, result)

      # The injected fault fires immediately BEFORE `Repo.insert`, so the row
      # cannot exist — a rescue that swallowed the fault into an empty success
      # would leave this assertion passing while `result` lied, hence both.
      assert {:error, :not_found} =
               Content.get_document(Content.draft_id(doc_id), "task", @dataset, scope)
    end

    test "with NO fault armed the create path is byte-for-byte unchanged", %{scope: scope} do
      Application.delete_env(:barkpark, :writer_fault)
      doc_id = uniq("dbconn-clean")

      assert {:ok, doc} = create(doc_id, scope)
      assert doc.doc_id == Content.draft_id(doc_id)
    end
  end

  # ── THE BLAST RADIUS IS BOUNDED, AND MEASURED ──────────────────────────────

  describe "the blast radius" do
    test "upsert_document/4 is NOT wrapped: the identical fault still raises there",
         %{scope: scope} do
      # Same exception, same struct, same message — the ONLY difference is the
      # door. If someone later widens the rescue to `do_upsert_document/5`,
      # this test reds and the widening has to be argued rather than absorbed.
      arm!(:upsert_prev_doc_lookup)

      assert_raise DBConnection.ConnectionError, fn ->
        Content.upsert_document("task", task_attrs(uniq("dbconn-upsert")), @dataset, scope)
      end
    end
  end
end
