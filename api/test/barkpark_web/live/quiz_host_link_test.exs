defmodule BarkparkWeb.QuizHostLinkTest do
  @moduledoc """
  Owner ruling #23 (2026-10-03, task-f5d0ce5677e1c1d0): binding a stored quiz
  to a room needs a Studio host link or a signed-in author session.

  Before this, anyone who knew a published quiz's id opened
  `/quiz/host/<pin>?quiz=<id>` and became its host: they read the private
  quiz's questions and heard every answer. Every refusal below is paired with
  an admitted path on the same quiz, so a dead route or an unpublished fixture
  cannot make a refute pass.
  """
  use BarkparkWeb.ConnCase, async: false

  @moduletag :requires_plugins

  import Phoenix.LiveViewTest

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Quiz
  alias Barkpark.Quiz.HostLink
  alias Barkpark.TenancyFixtures

  @dataset "production"

  setup do
    {ws, proj} = TenancyFixtures.ensure_default_scope!()
    scope = [workspace_id: ws.id, project_id: proj.id]

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

    n = System.unique_integer([:positive])
    qid = "quiz-link-#{n}"
    prompt = "HOST-LINK-PROMPT-#{n}"

    {:ok, _} =
      Content.upsert_document(
        "quiz",
        %{
          "doc_id" => qid,
          "prompt" => prompt,
          "choices" => [%{"id" => "a", "label" => "Alpha", "correct" => true}]
        },
        @dataset,
        scope
      )

    {:ok, _} = Content.publish_document(qid, "quiz", @dataset, scope)

    pin = "HL#{n}"
    on_exit(fn -> Quiz.stop_room(pin) end)

    %{ws: ws, qid: qid, prompt: prompt, pin: pin}
  end

  defp bound_quiz(pin) do
    Quiz.Bridge.bindings()
    |> Enum.find_value(fn {quiz_id, pins} -> if Map.has_key?(pins, pin), do: quiz_id end)
  end

  test "an anonymous host with no link gets the default question, not the quiz", ctx do
    {:ok, _view, html} = live(scoped_conn(), "/quiz/host/#{ctx.pin}?quiz=#{ctx.qid}")

    refute html =~ ctx.prompt
    assert html =~ "powers Barkpark"
    assert html =~ "Only the quiz&#39;s authors can host it"
    assert bound_quiz(ctx.pin) == nil
  end

  test "a forged token, or a link minted for another quiz, is refused", ctx do
    for token <- ["not-a-token", HostLink.sign("some-other-quiz")] do
      pin = ctx.pin <> "F#{System.unique_integer([:positive])}"
      on_exit(fn -> Quiz.stop_room(pin) end)

      {:ok, _view, html} =
        live(
          scoped_conn(),
          "/quiz/host/#{pin}?quiz=#{ctx.qid}&host=#{URI.encode_www_form(token)}"
        )

      refute html =~ ctx.prompt
      assert bound_quiz(pin) == nil
    end
  end

  test "an expired link is refused and says so", ctx do
    old = HostLink.sign(ctx.qid, now: System.system_time(:second) - 2 * HostLink.max_age())
    {:ok, _view, html} = live(scoped_conn(), "/quiz/host/#{ctx.pin}?quiz=#{ctx.qid}&host=#{old}")

    refute html =~ ctx.prompt
    assert html =~ "This host link has expired"
  end

  test "a valid Studio host link binds the quiz", ctx do
    link = "/quiz/host/#{ctx.pin}?quiz=#{ctx.qid}&host=#{HostLink.sign(ctx.qid)}"
    {:ok, _view, html} = live(scoped_conn(), link)

    assert html =~ ctx.prompt
    assert bound_quiz(ctx.pin) == ctx.qid
    refute html =~ "Only the quiz&#39;s authors can host it"
  end

  test "a signed-in Studio author binds without a link; a read-only session does not", ctx do
    writer = "qa-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, _} = Auth.create_token(writer, "author", @dataset, ["read", "write"], ctx.ws.id)

    {:ok, _view, html} =
      scoped_conn()
      |> Plug.Test.init_test_session(%{"api_token" => writer})
      |> live("/quiz/host/#{ctx.pin}?quiz=#{ctx.qid}")

    assert html =~ ctx.prompt

    reader = "qr-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    {:ok, _} = Auth.create_token(reader, "viewer", @dataset, ["read"], ctx.ws.id)
    pin = ctx.pin <> "R"
    on_exit(fn -> Quiz.stop_room(pin) end)

    {:ok, _view, html} =
      scoped_conn()
      |> Plug.Test.init_test_session(%{"api_token" => reader})
      |> live("/quiz/host/#{pin}?quiz=#{ctx.qid}")

    refute html =~ ctx.prompt
  end

  test "/quiz/host/new opens a fresh PIN and keeps the quiz and link", ctx do
    path = HostLink.path(ctx.qid)
    assert {:error, {:redirect, %{to: to}}} = live(scoped_conn(), path)

    %URI{path: "/quiz/host/" <> new_pin, query: query} = URI.parse(to)
    assert new_pin != "new"
    assert URI.decode_query(query)["quiz"] == ctx.qid
    on_exit(fn -> Quiz.stop_room(new_pin) end)

    {:ok, _view, html} = live(scoped_conn(), to)
    assert html =~ ctx.prompt
  end

  test "Studio's quiz editor offers a Host this quiz link that binds the quiz", ctx do
    doc = %{doc_id: ctx.qid}
    actions = Barkpark.Plugins.Quiz.resolve_doc_actions([], %{doc_type: "quiz", doc: doc})

    assert [%{"name" => "quiz_host", "kind" => "link", "opts" => %{"href" => href}}] = actions
    assert href =~ "/quiz/host/new?"
    host = URI.decode_query(URI.parse(href).query)["host"]
    assert HostLink.verify(host, ctx.qid) == :ok

    # Not on other types, and not for a quiz outside the Default workspace.
    assert Barkpark.Plugins.Quiz.resolve_doc_actions([], %{doc_type: "post", doc: doc}) == []
    other = TenancyFixtures.create_workspace!()

    assert Barkpark.Plugins.Quiz.resolve_doc_actions([], %{
             doc_type: "quiz",
             doc: doc,
             workspace_id: other.id
           }) == []
  end
end
