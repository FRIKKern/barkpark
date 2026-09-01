defmodule Barkpark.Content.ErrorsTest do
  use ExUnit.Case, async: false
  alias Barkpark.Content.Errors

  setup do
    prev = Logger.metadata()
    on_exit(fn -> Logger.reset_metadata(prev) end)
    :ok
  end

  test "maps not_found" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, :not_found})
    assert env.code == "not_found"
    assert env.message == "document not found"
    assert env.status == 404
    # hint is additive — code/message/status stay stable
    assert is_binary(env.hint) and env.hint != ""
    refute Map.has_key?(env, :request_id)
  end

  test "registers a fix-suggesting hint for known codes without mutating code/message/status" do
    Logger.metadata(request_id: nil)

    for {reason, code} <- [
          {{:error, :not_found}, "not_found"},
          {{:error, :unauthorized}, "unauthorized"},
          {{:error, :rate_limited}, "rate_limited"}
        ] do
      env = Errors.to_envelope(reason)
      assert env.code == code
      assert is_binary(env.hint) and env.hint != ""
    end
  end

  test "validation_failed changeset envelope carries a hint" do
    Logger.metadata(request_id: nil)

    cs =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    env = Errors.to_envelope({:error, cs})
    assert env.code == "validation_failed"
    assert is_binary(env.hint) and env.hint != ""
  end

  test "binary-reason (internal_error) envelope still works and carries its hint" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, "boom"})
    assert env.code == "internal_error"
    assert env.message == "boom"
    assert env.status == 500
    assert is_binary(env.hint) and env.hint != ""
  end

  # The catch-all's CODE is the stable half — `BarkparkCloud.Sites.Deploy.
  # transient_refusal?/1` keys its retry grace on it. The MESSAGE now names the
  # unmatched term's SHAPE (never its values) and the term is logged; both are
  # pinned in full, with the leak guards, in errors_unmatched_reason_test.exs.
  test "catch-all unknown reason maps to internal_error with a hint" do
    Logger.metadata(request_id: nil)

    {env, _log} = ExUnit.CaptureLog.with_log(fn -> Errors.to_envelope(:totally_unexpected) end)

    assert env.code == "internal_error"
    assert env.message == "unknown error (:totally_unexpected)"
    assert env.status == 500
    assert is_binary(env.hint) and env.hint != ""
  end

  test "maps changeset errors" do
    Logger.metadata(request_id: nil)

    cs =
      {%{}, %{title: :string}}
      |> Ecto.Changeset.cast(%{}, [:title])
      |> Ecto.Changeset.validate_required([:title])

    env = Errors.to_envelope({:error, cs})
    assert env.code == "validation_failed"
    assert env.status == 422
    assert env.details == %{title: ["can't be blank"]}
    refute Map.has_key?(env, :request_id)
  end

  test "maps rev mismatch" do
    Logger.metadata(request_id: nil)
    assert %{code: "rev_mismatch", status: 409} = Errors.to_envelope({:error, :rev_mismatch})
  end

  test "maps invalid_task_content to a 422 with the field errors" do
    Logger.metadata(request_id: nil)

    # Regression: a task create missing kind/lifecycle_status fell through to
    # the catch-all and surfaced as a 500 "unknown error" — a validation
    # failure with no signal about what to fix.
    errors = %{"kind" => ["is required"]}
    env = Errors.to_envelope({:error, {:invalid_task_content, errors}})
    assert env.code == "validation_failed"
    assert env.status == 422
    assert env.details == errors
  end

  test "to_envelope/2 with nil conn omits request_id when Logger metadata empty" do
    Logger.metadata(request_id: nil)
    env = Errors.to_envelope({:error, :not_found}, nil)
    refute Map.has_key?(env, :request_id)
  end

  test "to_envelope/2 pulls request_id from Logger metadata" do
    Logger.metadata(request_id: "test-req-123")
    conn = %Plug.Conn{}
    env = Errors.to_envelope({:error, :not_found}, conn)
    assert env.request_id == "test-req-123"
    assert env.code == "not_found"
    assert env.status == 404
  end

  test "to_envelope/2 falls back to x-request-id resp header when Logger metadata missing" do
    Logger.metadata(request_id: nil)
    conn = Plug.Conn.put_resp_header(%Plug.Conn{}, "x-request-id", "header-req-456")
    env = Errors.to_envelope({:error, :unauthorized}, conn)
    assert env.request_id == "header-req-456"
  end

  test "to_envelope/1 still works and omits request_id when metadata empty" do
    Logger.metadata(request_id: nil)
    env = Errors.to_envelope({:error, :forbidden})
    refute Map.has_key?(env, :request_id)
  end

  # A plugin lifecycle veto ({:halt, reason} → {:error, {:halted, reason}}) must
  # reach the bp CLI + SDK as the CANONICAL envelope — code "halted", 409, the
  # reason verbatim as the message, plus the additive hint. MutateController used
  # to emit a bare %{error: "halted", reason: reason} with no code/request_id;
  # this is the spine that makes the reroute conform. (Reverting the build/1
  # clause drops this to the binary/catch-all path → internal_error/500.)
  test "maps a plugin halt {:halted, reason} to a 409 with code \"halted\"" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:halted, "tenant is over quota"}})
    assert env.code == "halted"
    assert env.status == 409
    assert env.message == "tenant is over quota"
    # additive hint, like every other registered code
    assert is_binary(env.hint) and env.hint != ""
  end

  test "a non-binary halt reason still yields a non-empty halted message" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:halted, {:policy, :blocked}}})
    assert env.code == "halted"
    assert env.status == 409
    assert is_binary(env.message) and env.message != ""
  end

  test "an unknown filter operator maps to a 400 invalid_filter with field/op details" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:invalid_filter_op, "status", "bogus"}})
    assert env.code == "invalid_filter"
    assert env.status == 400
    assert env.details == %{field: "status", op: "bogus"}
    # names the bad op + lists valid ones, plus the additive hint
    assert env.message =~ "bogus"
    assert env.message =~ "startsWith"
    assert is_binary(env.hint) and env.hint != ""
  end

  test "a forbidden filter/order field maps to a 422 forbidden_field with details" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:forbidden_field, "salary"}})
    assert env.code == "forbidden_field"
    assert env.status == 422
    assert env.details == %{field: "salary"}
    assert is_binary(env.message) and env.message != ""
    assert is_binary(env.hint) and env.hint != ""
  end

  test "a media storage fault maps to a 503 storage_unavailable envelope with a hint" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, :storage_unavailable})
    assert env.code == "storage_unavailable"
    assert env.status == 503
    assert is_binary(env.message) and env.message != ""
    # additive hint like every other registered code
    assert is_binary(env.hint) and env.hint != ""
  end

  test "payload_too_large is a registered code so the OpenAPI enum advertises it" do
    # Emitted by the endpoint's parse_body rescue (RequestTooLargeError → 413);
    # registering it keeps the canonical §9 vocabulary complete.
    assert MapSet.member?(Errors.known_codes(), "payload_too_large")
  end

  test "resource-coded not_found ({:not_found, code, message}) carries the CODE's own hint" do
    Logger.metadata(request_id: nil)

    env = Errors.to_envelope({:error, {:not_found, "webhook_not_found", "webhook not found"}})
    assert env.code == "webhook_not_found"
    assert env.message == "webhook not found"
    assert env.status == 404
    # The hint is looked up by the RESOURCE code — not the document-centric
    # generic not_found hint.
    assert env.hint =~ "webhook id"
  end

  test "the webhook console's coded 404 pair is registered (OpenAPI enum truthful)" do
    # The webhook controller emits these at runtime; registering them keeps the
    # served Error.code enum + the hint lookup in sync with reality.
    assert MapSet.member?(Errors.known_codes(), "webhook_not_found")
    assert MapSet.member?(Errors.known_codes(), "event_not_found")
  end

  test "an UNREGISTERED resource code fails loud (vocabulary drift tripwire)" do
    assert_raise MatchError, fn ->
      Errors.to_envelope({:error, {:not_found, "gadget_not_found", "gadget not found"}})
    end
  end

  # ── Authoring-excellence E4 dedup wall (duplicate_of) ──────────────────────
  #
  # DELIBERATE membership test: the OpenAPI drift-guard is a TAUTOLOGY
  # (known_codes/0 derives from @hints), which is exactly how `duplicate_task`
  # slipped in with a build clause but no hint — invisible in the served spec
  # and untested. This pins the new code so it can't repeat that hole.
  test "duplicate_of IS a registered code (deliberate — not the duplicate_task hole)" do
    assert MapSet.member?(Errors.known_codes(), "duplicate_of")
  end

  test "duplicate_of maps to a 409 carrying the incumbent id and a fix-hint" do
    Logger.metadata(request_id: nil)

    env =
      Errors.to_envelope(
        {:error,
         {:duplicate_of,
          %{
            message: "document duplicates an already-published document",
            duplicate_of: "paper-live",
            similar: [%{id: "paper-live", similarity: 0.92, shared_tokens: 5}]
          }}}
      )

    assert env.code == "duplicate_of"
    assert env.status == 409
    assert env.details.duplicate_of == "paper-live"
    assert [%{id: "paper-live"} | _] = env.details.similar
    # additive hint like every other registered code
    assert is_binary(env.hint) and env.hint != ""
  end

  # The publish wall's label-spine rejection (authoring-excellence D5): a new
  # top-level atom — deliberately NOT the task-scoped invalid_task_content and
  # NOT the plugin {:halted, _} shape. The validator's documentation-grade
  # details (field / rule / fix) ride verbatim so an agent's one retry can be
  # exact.
  test "maps {:label_spine, details} to a 422 with the field/rule/fix details verbatim" do
    Logger.metadata(request_id: nil)

    details = %{
      field: "tags",
      rule: "A published document requires a `tags` array.",
      fix: "Add 1–12 weighted tags: [{tag, strength, rationale}]."
    }

    env = Errors.to_envelope({:error, {:label_spine, details}})
    assert env.code == "label_spine"
    assert env.status == 422
    assert env.details == details
    assert is_binary(env.message) and env.message != ""
    # additive fix-suggesting hint, like every other registered code
    assert is_binary(env.hint) and env.hint != ""
    # ae-ingest-learn-pointer: the hint teaches WHERE the standards live, not
    # only what broke — it points at both doctrine papers.
    assert env.hint =~ "portabledoc-doctrine"
    assert env.hint =~ "composition-doctrine-plan"
  end

  # DELIBERATE membership test (charter D5, amended): known_codes/0 derives
  # from @hints, which makes the OpenAPI drift-guard a tautology — a build
  # clause without an @hints entry is invisible in the served spec and no test
  # reds (live counter-example: duplicate_task). This assertion is the real
  # tripwire: drop the @hints entry and this fails.
  test "label_spine is a registered code (OpenAPI enum + hint table truthful)" do
    assert MapSet.member?(Errors.known_codes(), "label_spine")
  end
end
