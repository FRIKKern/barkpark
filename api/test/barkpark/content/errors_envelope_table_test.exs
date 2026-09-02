defmodule Barkpark.Content.ErrorsEnvelopeTableTest do
  @moduledoc """
  THE GOLDEN TABLE over every `Barkpark.Content.Errors.build/1` arm.

  WHY IT EXISTS. `to_envelope/2` is one shared function that every v1 door
  renders through, so a one-line edit to ONE arm — a status bumped, a `hint`
  added, a `details` key dropped — silently re-classifies whatever else that
  arm's `code` is shared with. The dedup-outage arm's 503 upgrade
  (dr-w32-bl-dedup-unavailable-is-an-outage-called-a-veto) is exactly that
  shape of edit: it moves ONE term from 409 to 503 while `{:halted, reason}`
  — which it shares the `halted` code with — must not move at all.

  WHAT IT PINS, per arm: the `code`, the HTTP `status`, and the exact KEY SET of
  the envelope (so an added or dropped `details`/`reason`/`hint` reds too). The
  MESSAGE is deliberately not pinned — several arms interpolate caller data, and
  their wording is pinned where it is load-bearing (errors_test.exs,
  errors_unmatched_reason_test.exs).

  NON-VACUITY. A table is worthless if an arm can be added without a row: the
  last test COUNTS the `defp build(` clauses in the source file and asserts the
  table has exactly that many rows. Add an arm and this file reds until it is
  described here.

  SCOPE NOTE (shared test database): every row is a pure function call on a
  literal term. Nothing touches `Repo`, so no other agent's rows can reach it.
  """
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Barkpark.Content.Errors

  @errors_source Path.expand("../../../lib/barkpark/content/errors.ex", __DIR__)

  setup do
    prev = Logger.metadata()
    on_exit(fn -> Logger.reset_metadata(prev) end)
    Logger.metadata(request_id: nil)
    :ok
  end

  # {label, reason term, expected code, expected status, keys BEYOND
  #  code/message/status/hint}. Every arm below builds a code that carries a
  # registered @hints entry (or sets its own hint), so `:hint` is present on all
  # of them; the extras column is where `details` / `reason` are declared.
  defp changeset do
    {%{}, %{title: :string}}
    |> Ecto.Changeset.cast(%{}, [:title])
    |> Ecto.Changeset.validate_required([:title])
  end

  defp table do
    [
      {"not_found", {:error, :not_found}, "not_found", 404, []},
      {"not_found/message", {:error, {:not_found, "secret not found"}}, "not_found", 404, []},
      {"not_found/coded", {:error, {:not_found, "webhook_not_found", "no such webhook"}},
       "webhook_not_found", 404, []},
      {"unauthorized", {:error, :unauthorized}, "unauthorized", 401, []},
      {"replay", {:error, :replay}, "unauthorized", 401, [:reason]},
      {"forbidden", {:error, :forbidden}, "forbidden", 403, []},
      {"forbidden_membership", {:error, :forbidden_membership}, "forbidden", 403, [:reason]},
      {"workspace_suspended", {:error, :workspace_suspended}, "workspace_suspended", 403, []},
      {"workspace_suspended/reason", {:error, {:workspace_suspended, "abuse"}},
       "workspace_suspended", 403, [:details]},
      {"quota_exceeded", {:error, :quota_exceeded}, "quota_exceeded", 402, []},
      {"quota_exceeded/quota", {:error, {:quota_exceeded, %{writes: 10}}}, "quota_exceeded", 402,
       [:details]},
      {"forbidden_origin", {:error, :forbidden_origin}, "cors_forbidden", 403, []},
      {"csrf_required", {:error, :csrf_required}, "csrf_required", 403, []},
      {"schema_unknown", {:error, :schema_unknown}, "schema_unknown", 404, []},
      {"rev_mismatch", {:error, :rev_mismatch}, "rev_mismatch", 409, []},
      {"rev_mismatch/expected-actual", {:error, {:rev_mismatch, %{expected: "a", actual: "b"}}},
       "precondition_failed", 412, [:details]},
      {"malformed", {:error, :malformed}, "malformed", 400, []},
      {"unsupported_if_match_for_batch", {:error, :unsupported_if_match_for_batch},
       "unsupported_if_match_for_batch", 400, []},
      {"invalid_filter_op", {:error, {:invalid_filter_op, "status", "bogus"}}, "invalid_filter",
       400, [:details]},
      {"InvalidFilterError", {:error, Barkpark.Content.InvalidFilterError.new("status", "bogus")},
       "invalid_filter", 400, [:details]},
      {"invalid_flat_filter", {:error, {:invalid_flat_filter, "price>"}}, "invalid_filter", 400,
       [:details]},
      {"invalid_filter_clause", {:error, {:invalid_filter_clause, "bad value", %{field: "tags"}}},
       "invalid_filter", 400, [:details]},
      {"invalid_filter/legacy", {:error, {:invalid_filter, "price>10"}}, "invalid_filter", 400,
       [:details]},
      {"forbidden_field", {:error, {:forbidden_field, "secret"}}, "forbidden_field", 422,
       [:details]},
      {"conflict", {:error, :conflict}, "conflict", 409, []},
      {"idempotency_key_in_use", {:error, :idempotency_key_in_use}, "idempotency_key_in_use", 409,
       []},
      # THE VETO — deterministic, 409, and it must NOT move when the outage arm
      # below does.
      {"halted", {:error, {:halted, "tenant is over quota"}}, "halted", 409, []},
      # THE OUTAGE — transient, 503, its own retry hint, `reason` discriminating
      # it from the veto it shares a code with.
      {"dedup_unavailable", {:error, {:dedup_unavailable, "backlog scan timed out"}}, "halted",
       503, [:reason]},
      {"label_spine", {:error, {:label_spine, %{"tags" => ["required"]}}}, "label_spine", 422,
       [:details]},
      {"invalid_paper_structure", {:error, {:invalid_paper_structure, %{"blocks" => []}}},
       "invalid_paper_structure", 422, [:details]},
      {"invalid_epic_paper_quality", {:error, {:invalid_epic_paper_quality, %{failures: []}}},
       "invalid_epic_paper_quality", 422, [:details]},
      {"duplicate_task", {:error, {:duplicate_task, %{similar: []}}}, "duplicate_task", 409,
       [:details]},
      {"duplicate_of", {:error, {:duplicate_of, %{duplicate_of: "doc-1"}}}, "duplicate_of", 409,
       [:details]},
      {"unknown_tag", {:error, {:unknown_tag, %{unknown: ["nope"], suggestions: []}}},
       "unknown_tag", 422, [:details]},
      {"invalid_dataset", {:error, {:invalid_dataset, %{"dataset" => ["is invalid"]}}},
       "validation_failed", 422, [:details]},
      {"changeset", {:error, changeset()}, "validation_failed", 422, [:details]},
      {"invalid_task_content", {:error, {:invalid_task_content, %{"kind" => ["is required"]}}},
       "validation_failed", 422, [:details]},
      {"invalid_schema_fields", {:error, {:invalid_schema_fields, :missing_name}},
       "validation_failed", 422, [:details]},
      {"schema_has_documents", {:error, {:schema_has_documents, 3}}, "schema_has_documents", 409,
       [:details]},
      {"rate_limited", {:error, :rate_limited}, "rate_limited", 429, []},
      {"storage_unavailable", {:error, :storage_unavailable}, "storage_unavailable", 503, []},
      {"unsupported_media_type", {:error, :unsupported_media_type}, "unsupported_media_type", 422,
       []},
      {"payload_too_large", {:error, :payload_too_large}, "payload_too_large", 413, []},
      {"rate_limited/retry_after", {:error, :rate_limited, %{retry_after: 30}}, "rate_limited",
       429, [:details]},
      {"binary reason", {:error, "boom"}, "internal_error", 500, []},
      {"unknown sentinel", {:error, :unknown}, "internal_error", 500, []},
      {"catch-all", :totally_unexpected, "internal_error", 500, []}
    ]
  end

  test "every to_envelope arm renders its pinned code, status and key set" do
    # The catch-all arm LOGS by design; capture so the table run is quiet.
    capture_log(fn ->
      for {label, term, code, status, extras} <- table() do
        env = Errors.to_envelope(term)
        expected_keys = Enum.sort([:code, :message, :status, :hint | extras])

        assert {label, env.code, env.status, Enum.sort(Map.keys(env))} ==
                 {label, code, status, expected_keys},
               "the #{label} arm's envelope moved — a shared-envelope change " <>
                 "re-classified it. Expected code=#{code} status=#{status} " <>
                 "keys=#{inspect(expected_keys)}, got code=#{env.code} " <>
                 "status=#{env.status} keys=#{inspect(Enum.sort(Map.keys(env)))}."

        assert is_binary(env.message) and env.message != "",
               "the #{label} arm rendered an empty message"

        assert is_binary(env.hint) and env.hint != "",
               "the #{label} arm rendered an empty hint"
      end
    end)
  end

  # ── The transient-outage arm, pinned in full (criterion 1) ──────────────────

  test "a dedup outage renders a RETRYABLE 503 whose hint tells the caller to resend" do
    env = Errors.to_envelope({:error, {:dedup_unavailable, "backlog scan timed out"}})

    assert env.status == 503, "a transient dedup outage must not render as a 4xx"
    assert env.message == "backlog scan timed out"
    assert env.reason == "dedup_unavailable"
    assert env.hint =~ "Transient"
    assert env.hint =~ "Resend the identical request"

    refute env.hint =~ "adjust the document",
           "the plugin-veto hint tells the caller to edit a document that is fine"
  end

  test "the plugin VETO stays a deterministic 409 with the veto hint (the split holds)" do
    env = Errors.to_envelope({:error, {:halted, "tenant is over quota"}})

    assert env.status == 409
    assert env.code == "halted"
    assert env.hint =~ "plugin's lifecycle hook vetoed this write"
    refute Map.has_key?(env, :reason)
  end

  # ── Non-vacuity: the table must describe EVERY arm ──────────────────────────

  test "the table has one row per build/1 clause (a new arm cannot slip through)" do
    source = File.read!(@errors_source)

    arms =
      source
      |> String.split("\n")
      |> Enum.count(&String.starts_with?(&1, "  defp build("))

    assert arms > 40, "the arm counter found #{arms} clauses — it stopped matching the source"

    assert length(table()) == arms,
           "Content.Errors has #{arms} build/1 clauses but this table describes " <>
             "#{length(table())}. Every arm must carry a row here, or a status/shape " <>
             "change to the new one ships unpinned."
  end
end
