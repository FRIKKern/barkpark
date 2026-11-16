defmodule BarkparkWeb.Studio.WebhooksLiveTest do
  @moduledoc """
  The Studio Webhooks page: an admin adds a webhook and sees its secret once;
  a member is refused; an admin never sees or touches another workspace's or
  another project's hooks; test and replay reach the receiver; delete and
  rotate ask first; the secret never stays in the socket, a log or an audit row.
  """
  use BarkparkWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Phoenix.LiveViewTest
  import Barkpark.TenancyFixtures

  alias Barkpark.{Accounts, Repo, Tenancy, Webhooks}
  alias Barkpark.Content.MutationEvent

  # Both workspaces use this dataset name on purpose: the workspace must keep
  # them apart, not the name.
  @dataset "production"

  defmodule RecordingHTTP do
    def post(url, body, headers) do
      if pid = Application.get_env(:barkpark, :webhooks_live_test_pid),
        do: send(pid, {:webhook_post, url, body, headers})

      {:ok, 204}
    end
  end

  setup %{conn: conn} do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)
    Application.put_env(:barkpark, :webhook_http_adapter, RecordingHTTP)
    Application.put_env(:barkpark, :webhooks_live_test_pid, self())

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      Application.delete_env(:barkpark, :webhooks_live_test_pid)
    end)

    {ws, proj} = workspace!("hooks-a")
    {other, other_proj} = workspace!("hooks-b")
    {:ok, conn: conn, ws: ws, proj: proj, other: other, other_proj: other_proj}
  end

  test "an admin adds a webhook, sees it listed, and sees the secret once", ctx do
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    {:ok, view, html} = live(conn, path(ctx.ws))
    assert html =~ "No webhooks yet."

    view |> element("button", "Add a webhook") |> render_click()

    {html, log} =
      with_prod_log(fn ->
        view
        |> form("#webhook-form",
          webhook: %{name: "Site", url: "https://example.com/hook", events: ["publish"]}
        )
        |> render_submit()
      end)

    [secret] = Regex.run(~r/whsec_[A-Za-z0-9_-]+/, html)

    assert [%{name: "Site", url: "https://example.com/hook", events: ["publish"]} = wh] =
             Webhooks.list_webhooks(@dataset, workspace_id: ctx.ws.id)

    assert wh.secret == secret
    assert wh.project_id == ctx.proj.id
    assert view |> element("[data-test-id=webhook-row]") |> render() =~ "https://example.com/hook"

    # Right after that render the socket holds no secret (the reveal box keeps
    # what the browser got), and no log line or audit row carries it.
    refute socket_holds?(view, secret)
    refute log =~ secret
    refute audit_holds?(secret)

    view |> element("button", "Done") |> render_click()
    refute render(view) =~ secret

    {:ok, _again, html} = live(conn, path(ctx.ws))
    refute html =~ secret
    refute html =~ "whsec_"
  end

  test "a member who is not an admin is refused", ctx do
    assert {:error, {:redirect, %{to: "/studio", flash: flash}}} =
             live(sign_in(ctx.conn, ctx.ws, "member"), path(ctx.ws))

    assert flash["error"] == "Admin access required"
  end

  test "an admin sees this project's hooks and workspace-wide ones, never another tenant's",
       ctx do
    mine = hook!(ctx.ws, ctx.proj, "mine")
    wide = hook!(ctx.ws, nil, "workspace-wide")
    sibling = hook!(ctx.ws, create_project!(ctx.ws, "other"), "sibling-project")
    theirs = hook!(ctx.other, ctx.other_proj, "other-workspace")

    {:ok, view, html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws))

    assert html =~ mine.url
    assert html =~ wide.url
    assert view |> element("#webhook-#{wide.id}") |> render() =~ "every project"
    refute html =~ sibling.url
    refute html =~ theirs.url

    # Forged events naming the other workspace's hook touch nothing.
    for {event, params} <- [
          {"ask", %{"action" => "delete", "id" => theirs.id}},
          {"delete", %{"id" => theirs.id}},
          {"ask", %{"action" => "rotate", "id" => theirs.id}},
          {"rotate", %{"id" => theirs.id}},
          {"toggle", %{"id" => theirs.id}},
          {"test", %{"id" => theirs.id}},
          {"replay", %{"id" => theirs.id, "event_id" => "1"}},
          {"edit", %{"id" => theirs.id}},
          {"deliveries", %{"id" => theirs.id}}
        ],
        do: render_click(view, event, params)

    refute_received {:webhook_post, _, _, _}
    assert {:ok, untouched} = Webhooks.get_webhook(theirs.id)
    assert untouched.active and untouched.secret == theirs.secret
    refute render(view) =~ theirs.url
  end

  test "send test and replay reach the receiver", ctx do
    hook = hook!(ctx.ws, ctx.proj, "receiver")
    event = event!(ctx.ws, ctx.proj)
    {:ok, _} = Webhooks.claim_delivery(hook.id, event.id)

    {:ok, view, _html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws))

    view |> element("button", "Send test") |> render_click()
    assert_received {:webhook_post, "https://example.com/receiver", body, _headers}
    assert body =~ "webhook.test"
    assert view |> element("[data-test-id=webhook-test-result]") |> render() =~ "delivered (204)"

    view |> element("button", "Deliveries") |> render_click()
    view |> element("[data-test-id=webhook-delivery-row] button", "Send again") |> render_click()

    assert_received {:webhook_post, "https://example.com/receiver", body, _headers}
    assert body =~ event.doc_id
    assert render(view) =~ "Sent again. The receiver answered 204."
  end

  test "delete and a new secret both ask first", ctx do
    hook = hook!(ctx.ws, ctx.proj, "doomed")
    {:ok, view, _html} = live(sign_in(ctx.conn, ctx.ws, "admin"), path(ctx.ws))

    # A lone event, without the question, does nothing.
    render_click(view, "delete", %{"id" => hook.id})
    render_click(view, "rotate", %{"id" => hook.id})
    assert {:ok, %{secret: same}} = Webhooks.get_webhook(hook.id)
    assert same == hook.secret

    view |> element("button", "New secret") |> render_click()
    html = view |> element("button", "Yes, make a new secret") |> render_click()
    [secret] = Regex.run(~r/whsec_[A-Za-z0-9_-]+/, html)
    assert {:ok, %{secret: ^secret}} = Webhooks.get_webhook(hook.id)
    refute socket_holds?(view, secret)

    view |> element("#webhook-#{hook.id} button", "Delete") |> render_click()
    assert view |> element("[data-test-id=webhook-confirm-delete]") |> render() =~ "Delete this"
    view |> element("button", "Yes, delete") |> render_click()

    assert {:error, :not_found} = Webhooks.get_webhook(hook.id)
  end

  test "an admin demoted after opening the page can no longer send a test", ctx do
    hook!(ctx.ws, ctx.proj, "demoted")
    conn = sign_in(ctx.conn, ctx.ws, "admin")
    {:ok, view, _html} = live(conn, path(ctx.ws))

    {:ok, _} =
      Tenancy.Members.update_role(ctx.ws.id, %{type: :user, id: conn.assigns.user.id}, "member")

    assert {:error, {:redirect, %{to: "/studio"}}} =
             view |> element("button", "Send test") |> render_click()

    refute_received {:webhook_post, _, _, _}
  end

  defp path(ws), do: "/w/#{ws.slug}/p/default/d/#{@dataset}/studio/_webhooks"

  defp workspace!(name) do
    ws = create_workspace!("#{name}-#{System.unique_integer([:positive])}")
    proj = create_project!(ws, "default")
    {:ok, _} = Tenancy.get_or_create_dataset(proj, @dataset)
    {ws, proj}
  end

  defp hook!(ws, proj, name) do
    {:ok, wh} =
      Webhooks.create_webhook(
        %{
          "name" => name,
          "url" => "https://example.com/#{name}",
          "dataset" => @dataset,
          "secret" => "whsec_fixture_#{name}"
        },
        workspace_id: ws.id,
        project_id: proj && proj.id
      )

    wh
  end

  defp event!(ws, proj) do
    %MutationEvent{}
    |> Ecto.Changeset.change(%{
      dataset: @dataset,
      workspace_id: ws.id,
      project_id: proj.id,
      type: "post",
      doc_id: "doc-#{System.unique_integer([:positive])}",
      mutation: "publish",
      rev: "rev-1",
      document: %{"_id" => "doc", "title" => "Hello"},
      inserted_at: DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp sign_in(conn, ws, role) do
    email = "hooks-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Accounts.register_user(%{email: email, password: "correct-horse-battery"})
    {:ok, _} = Tenancy.Auth.create_membership(ws.id, user.id, role, "user")
    {:ok, raw} = Accounts.create_user_session_token(user)

    conn |> Plug.Test.init_test_session(%{"user_session" => raw}) |> Plug.Conn.assign(:user, user)
  end

  # The LiveView process's whole state, socket assigns included.
  defp socket_holds?(view, secret) do
    view.pid
    |> :sys.get_state()
    |> inspect(limit: :infinity, printable_limit: :infinity)
    |> String.contains?(secret)
  end

  defp audit_holds?(secret) do
    %{rows: [[n]]} =
      Repo.query!("SELECT count(*) FROM audit_events WHERE metadata::text LIKE $1", [
        "%#{secret}%"
      ])

    n > 0
  end

  # Every log line production writes (`:info` and up, config/prod.exs) while
  # `fun` runs. Below that, Ecto's debug query log prints insert parameters,
  # the secret column included, on every webhook write in dev and test.
  defp with_prod_log(fun) do
    level = Logger.level()
    Logger.configure(level: :info)

    try do
      ref = make_ref()
      log = capture_log([level: :info], fn -> send(self(), {ref, fun.()}) end)
      receive do: ({^ref, result} -> {result, log})
    after
      Logger.configure(level: level)
    end
  end
end
