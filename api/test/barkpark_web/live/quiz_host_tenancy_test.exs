defmodule BarkparkWeb.QuizHostTenancyTest do
  @moduledoc """
  The tenant + perspective fence on the ANONYMOUS quiz host door
  (task-025f39c06543e27c), driven through the REAL router as a tokenless caller.

  `live("/quiz/host/:pin", QuizHostLive)` is contributed by the quiz plugin on
  the `:public_root` bucket — the `:browser` pipeline, no `on_mount` gate, no
  token, no `current_workspace` assign. Its mount takes a CLIENT-SUPPLIED
  document id straight off the query string (`?quiz=<id>`), binds the room to it
  and renders it on the projector, which reaches `Quiz.Content.load_question/2`.

  That read called `Content.get_document(quiz_id, "quiz", dataset)` at 3-arity,
  so `opts == []`. Per `Content.Query.get_document/4`'s own contract a nil
  `:workspace_id` there is an EXPLICIT GLOBAL read
  (`Scope.scope_to_workspace_or_global/3`) and there is no perspective clamp, so:

    * a quiz row in ANOTHER workspace whose `dataset_id` is NULL — a
      workspace-only write, or any legacy pre-tenancy row; `scope_to_dataset/3`
      matches them with `is_nil(dataset_id) and dataset == ^dataset` — was
      returned to any visitor who typed its id, and
    * `?quiz=drafts.<id>` addressed the UNPUBLISHED draft row directly.

  The `quiz` type is PRIVATE for a stated reason (`Quiz.Content.schema/0`: the
  doc stores the correct answer inline), and the carve-out one comment up
  exempts this server-side load from the VISIBILITY gate. It says nothing about
  TENANCY or perspective — so the one read the codebase deliberately exempted
  from visibility was also the one with no tenant gate, on the one route with no
  auth.

  ## The fence

  `load_question/2` now resolves through `Content.get_public_document/3` — the
  SAME anonymous-surface resolver the sibling `:public_root` readers already use
  (`BulldocsLive` via `get_public_paper/2`, `SheetsReaderLive` via
  `Content.get_public_document("sheet", …)`): pinned to the seeded **Default**
  workspace, `published_only: true` hard-coded, fail-closed when no Default is
  seeded.

  ## Why this fixture can actually produce the leak

  A single-workspace fixture CANNOT catch a cross-tenant read — a reader that
  dropped its scope returns the same rows whether or not the boundary is
  enforced (`Barkpark.TenancyFixtures` moduledoc). So every case seeds BOTH
  tenants: a quiz in the Default workspace AND a quiz in a second workspace B,
  and the anonymous caller — holding a pin that grants it nothing beyond the
  public tenant — asks for B's id. The pre-fix reader really does return B's
  row and its inline answer key (proved by removing the fence; see the row's
  non-vacuity run).

  Every negative is paired with a POSITIVE CONTROL on the same anonymous route,
  so a blanket 403/404, a disabled plugin, or a dead reader can never make a
  refute pass for the wrong reason.
  """
  use BarkparkWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Barkpark.Content
  alias Barkpark.Quiz
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    {ws_default, proj_default} = TenancyFixtures.ensure_default_scope!()

    # Workspace B is deliberately PROJECT-LESS: a workspace-only write leaves
    # `dataset_id` NULL, which is the row shape `scope_to_dataset/3` matches
    # across EVERY tenant (`is_nil(dataset_id) and dataset == ^dataset`) — the
    # same shape every legacy pre-tenancy row carries. That is what makes this
    # fixture able to produce the leak instead of being incidentally saved by
    # the dataset_id filter.
    ws_b = TenancyFixtures.create_workspace!()

    default_scope = [workspace_id: ws_default.id, project_id: proj_default.id]
    b_scope = [workspace_id: ws_b.id]

    register_quiz_schema(default_scope)
    register_quiz_schema(b_scope)

    n = System.unique_integer([:positive])
    pins = for i <- 1..5, do: "QT#{i}X#{n}"
    on_exit(fn -> Enum.each(pins, &Quiz.stop_room/1) end)

    %{
      default_scope: default_scope,
      b_scope: b_scope,
      pins: pins,
      n: n
    }
  end

  # ── Preconditions ─────────────────────────────────────────────────────────
  #
  # `config/test.exs` ships feature flags OFF. If the quiz plugin were disabled
  # in test, every refute below would pass on a route that does not exist and
  # prove nothing. Assert the subject exists FIRST — and as a BOOLEAN, because
  # ExUnit discards the message on a match-assert.

  test "PRECONDITION: the quiz plugin is ENABLED here and mounts /quiz/host/:pin on :public_root" do
    contributed? =
      Barkpark.Plugins.Quiz.register_routes([])
      |> Enum.any?(fn
        {:live, "/quiz/host/:pin", BarkparkWeb.QuizHostLive, _action, opts} ->
          Keyword.get(opts, :auth) == :public_root

        _ ->
          false
      end)

    assert contributed?,
           "the quiz plugin must contribute /quiz/host/:pin on :public_root — " <>
             "without it every assertion in this file is vacuous"

    route =
      Phoenix.Router.route_info(BarkparkWeb.Router, "GET", "/quiz/host/PINPIN", "www.example.com")

    live_route? = is_map(route) and route.plug == Phoenix.LiveView.Plug

    assert live_route?,
           "GET /quiz/host/:pin must be a compiled LiveView route in the host router, " <>
             "got #{inspect(route)}"
  end

  test "PRECONDITION: the door is ANONYMOUS — a tokenless GET renders 200", %{pins: pins} do
    conn = get(build_conn(), "/quiz/host/#{Enum.at(pins, 0)}")
    assert html_response(conn, 200) =~ "Hyperquiz"
  end

  # ── Reachability (the positive control the refutes lean on) ───────────────

  test "REACHABILITY: an anonymous host renders the PUBLIC tenant's OWN quiz, answer stripped", %{
    default_scope: default_scope,
    pins: pins,
    n: n
  } do
    pin = Enum.at(pins, 1)
    qid = "quiz-own-#{n}"
    prompt = "DEFAULT-WS-PROMPT-#{n}"
    answer_key = "ANSWERKEY-DEFAULT-#{n}"

    publish_quiz!(qid, prompt, answer_key, default_scope)

    # The row really is there under the public tenant's own scope, so the render
    # below is the fence ADMITTING a legitimate read, not an accident.
    assert {:ok, _} = Content.get_document(qid, "quiz", @dataset, default_scope)

    {:ok, _view, html} = live(build_conn(), "/quiz/host/#{pin}?quiz=#{qid}")

    assert html =~ prompt
    assert Quiz.state(pin).question.prompt == prompt

    # The crown jewel. The correct choice's ID is the answer key; QuizHostLive
    # renders `choice.label` and a tally lookup — never `choice.id`, never
    # `question.answer` — so the key must be absent from the wire bytes.
    refute html =~ answer_key,
           "ANSWER LEAK: the correct-answer key reached the anonymous host body"

    stripped? = not Map.has_key?(Quiz.state(pin).question, :answer)

    assert stripped?,
           "Room.public_question/1 must delete :answer from the snapshot the host " <>
             "and every joined player socket read"
  end

  # ── The tenant fence ──────────────────────────────────────────────────────

  test "LEAK GUARD: an anonymous host CANNOT load workspace B's quiz by id", %{
    default_scope: default_scope,
    b_scope: b_scope,
    pins: pins,
    n: n
  } do
    pin = Enum.at(pins, 2)

    # BOTH tenants hold a quiz. The anonymous caller holds a pin that grants it
    # nothing beyond the public tenant, and asks for B's id.
    a_qid = "quiz-a-#{n}"
    b_qid = "quiz-b-#{n}"
    b_prompt = "TENANT-B-SECRET-PROMPT-#{n}"
    b_answer_key = "ANSWERKEY-TENANT-B-#{n}"

    publish_quiz!(a_qid, "DEFAULT-WS-PROMPT-#{n}", "ANSWERKEY-DEFAULT-#{n}", default_scope)
    publish_quiz!(b_qid, b_prompt, b_answer_key, b_scope)

    # The subject EXISTS: B's row is really in the database, really carries the
    # secret prompt, and really carries the inline answer key. Without this the
    # refutes below could pass on a nil and prove nothing.
    {:ok, b_doc} = Content.get_document(b_qid, "quiz", @dataset, b_scope)
    assert b_doc.content["prompt"] == b_prompt

    b_answer_stored? =
      Enum.any?(b_doc.content["choices"], &(&1["id"] == b_answer_key and &1["correct"]))

    assert b_answer_stored?,
           "workspace B's stored quiz must carry the inline answer key — otherwise " <>
             "\"the answer did not leak\" is vacuous"

    {:ok, _view, html} = live(build_conn(), "/quiz/host/#{pin}?quiz=#{b_qid}")

    refute html =~ b_prompt,
           "CROSS-TENANT LEAK: workspace B's private quiz rendered on an anonymous projector"

    refute html =~ b_answer_key,
           "CROSS-TENANT ANSWER LEAK: workspace B's inline answer key reached an " <>
             "anonymous response body"

    # Honest degrade, not a crash: an unresolvable quiz leaves the room on its
    # hardcoded default question (the existing `bind_quiz` no-op contract), and
    # the room the players read never holds B's content either.
    assert html =~ "powers Barkpark"
    assert Quiz.state(pin).question.prompt =~ "powers Barkpark"

    refute Quiz.state(pin).question.prompt == b_prompt,
           "CROSS-TENANT LEAK: workspace B's question was pushed into the live room"
  end

  test "LEAK GUARD: a colliding doc_id resolves to the PUBLIC tenant's row, deterministically", %{
    default_scope: default_scope,
    b_scope: b_scope,
    pins: pins,
    n: n
  } do
    pin = Enum.at(pins, 3)
    qid = "quiz-collide-#{n}"

    # The SAME doc_id, type and dataset string in both tenants — slugs are
    # per-workspace, so this is a legal state. Isolation can only come from
    # `workspace_id`: an unscoped `Repo.one` over both rows is not merely
    # leaky, it is non-deterministic.
    a_prompt = "DEFAULT-WS-PROMPT-#{n}"
    b_prompt = "TENANT-B-SECRET-PROMPT-#{n}"
    b_answer_key = "ANSWERKEY-TENANT-B-#{n}"

    publish_quiz!(qid, a_prompt, "ANSWERKEY-DEFAULT-#{n}", default_scope)
    publish_quiz!(qid, b_prompt, b_answer_key, b_scope)

    both_exist? =
      match?({:ok, _}, Content.get_document(qid, "quiz", @dataset, default_scope)) and
        match?({:ok, _}, Content.get_document(qid, "quiz", @dataset, b_scope))

    assert both_exist?,
           "both tenants must really hold a row at #{qid} — the collision is the fixture"

    {:ok, _view, html} = live(build_conn(), "/quiz/host/#{pin}?quiz=#{qid}")

    refute html =~ b_prompt, "CROSS-TENANT LEAK: B's colliding row won the resolve"
    refute html =~ b_answer_key, "CROSS-TENANT ANSWER LEAK: B's answer key reached the body"

    assert html =~ a_prompt
    assert Quiz.state(pin).question.prompt == a_prompt
  end

  # ── The perspective fence ─────────────────────────────────────────────────

  test "LEAK GUARD: ?quiz=drafts.<id> cannot address an unpublished quiz", %{
    default_scope: default_scope,
    pins: pins,
    n: n
  } do
    pin = Enum.at(pins, 4)
    qid = "quiz-draft-#{n}"
    draft_prompt = "UNPUBLISHED-DRAFT-PROMPT-#{n}"
    draft_answer_key = "ANSWERKEY-DRAFT-#{n}"

    # Created, never published — `Writer.create_document/4` force-prefixes every
    # new row, so the content lives at `drafts.<qid>` and only there.
    {:ok, _} = upsert_quiz!(qid, draft_prompt, draft_answer_key, default_scope)

    {:ok, draft} = Content.get_document("drafts." <> qid, "quiz", @dataset, default_scope)

    assert draft.content["prompt"] == draft_prompt,
           "the draft row must really carry the unpublished prompt — else the refute is vacuous"

    {:ok, _view, html} = live(build_conn(), "/quiz/host/#{pin}?quiz=drafts.#{qid}")

    refute html =~ draft_prompt,
           "DRAFT LEAK: an unpublished quiz rendered on the anonymous projector"

    refute html =~ draft_answer_key,
           "DRAFT ANSWER LEAK: an unpublished quiz's answer key reached the body"

    assert html =~ "powers Barkpark"
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  # The REAL schema the plugin registers — `visibility: "private"`, because the
  # doc stores the answer inline. Registered PER-WORKSPACE: schema rows are
  # workspace-scoped, so B needs its own before a `quiz` doc can be written there.
  defp register_quiz_schema(scope) do
    s = Quiz.Content.schema()

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => s.name,
          "title" => s.title,
          "visibility" => s.visibility,
          "fields" => s.fields
        },
        @dataset,
        scope
      )
  end

  # `answer_key` is the CORRECT choice's id — a distinctive string that lands in
  # the parsed question's `:answer` field and appears NOWHERE in a correctly
  # rendered host body.
  defp upsert_quiz!(qid, prompt, answer_key, scope) do
    Content.upsert_document(
      "quiz",
      %{
        "doc_id" => qid,
        "prompt" => prompt,
        "choices" => [
          %{"id" => answer_key, "label" => "Alpha", "correct" => true},
          %{"id" => "wrong-#{qid}", "label" => "Beta"}
        ]
      },
      @dataset,
      scope
    )
  end

  # Create + publish into `scope`. `load_question/2` reads the published
  # perspective, so the publish is what makes the row addressable at all.
  defp publish_quiz!(qid, prompt, answer_key, scope) do
    {:ok, _} = upsert_quiz!(qid, prompt, answer_key, scope)
    {:ok, _} = Content.publish_document(qid, "quiz", @dataset, scope)
  end
end
