defmodule Barkpark.Webhooks.AuditWebhooksTest do
  @moduledoc """
  Auth-event webhooks (era-w7): matching semantics + the Audit.emit → dispatcher
  bridge, riding the existing signed/retried delivery machine.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query
  alias Barkpark.{Audit, Repo, Tenancy, Webhooks}
  alias Barkpark.Webhooks.Dispatcher

  # A module-based adapter whose `post/3` echoes to a pid stored in config, so a
  # synchronous `deliver/3` is observable.
  defmodule PidEcho do
    def post(url, body, _headers) do
      case Application.get_env(:barkpark, :audit_webhook_test_pid) do
        pid when is_pid(pid) -> send(pid, {:delivered, url, body})
        _ -> :ok
      end

      {:ok, 200}
    end
  end

  setup do
    prev = Application.get_env(:barkpark, :webhook_http_adapter)

    # `fetch_env/2`, not `get_env/2`. The SSRF kill switch is a BOOLEAN: a
    # `false` default is indistinguishable from "never set", and putting an
    # explicit `false` back where there was no key leaves the guard in a state
    # this module chose rather than the one it found.
    prev_private = Application.fetch_env(:barkpark, :allow_private_outbound)

    Application.put_env(:barkpark, :webhook_http_adapter, PidEcho)
    Application.put_env(:barkpark, :audit_webhook_test_pid, self())
    Application.put_env(:barkpark, :allow_private_outbound, true)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:barkpark, :webhook_http_adapter, prev),
        else: Application.delete_env(:barkpark, :webhook_http_adapter)

      # Application env is VM-global. Leaked ON, the SSRF guard is disarmed for
      # whatever module ExUnit shuffles in next, and one of its tests can then
      # pass for the wrong reason.
      case prev_private do
        {:ok, v} -> Application.put_env(:barkpark, :allow_private_outbound, v)
        :error -> Application.delete_env(:barkpark, :allow_private_outbound)
      end

      Application.delete_env(:barkpark, :audit_webhook_test_pid)
    end)

    {:ok, org} = Tenancy.create_organization(%{slug: "auditwh", name: "Audit WH"})
    %{org: org}
  end

  defp sub(attrs) do
    {:ok, wh} =
      Webhooks.create_webhook(
        Map.merge(
          %{"name" => "audit-sub", "url" => "https://sink.example/hook", "secret" => "sek"},
          attrs
        )
      )

    wh
  end

  describe "audit_webhooks_for matching" do
    test "matches on category; content webhooks are excluded", %{org: org} do
      a = sub(%{"audit_categories" => ["auth"], "organization_id" => org.id})
      _content = sub(%{"events" => ["publish"], "audit_categories" => []})

      ids = Webhooks.audit_webhooks_for("auth", "sso_login", org.id) |> Enum.map(& &1.id)
      assert a.id in ids
      assert length(ids) == 1
    end

    test "audit_actions narrows within the category", %{org: org} do
      only_login =
        sub(%{
          "audit_categories" => ["auth"],
          "audit_actions" => ["sso_login"],
          "organization_id" => org.id
        })

      assert [%{id: id}] = Webhooks.audit_webhooks_for("auth", "sso_login", org.id)
      assert id == only_login.id
      assert [] == Webhooks.audit_webhooks_for("auth", "mfa_failed", org.id)
    end

    test "org scope: org-scoped fires only for its org; global sees all", %{org: org} do
      {:ok, other} = Tenancy.create_organization(%{slug: "other", name: "Other"})
      scoped = sub(%{"audit_categories" => ["token"], "organization_id" => org.id})
      global = sub(%{"audit_categories" => ["token"]})

      for_org = Webhooks.audit_webhooks_for("token", "minted", org.id) |> Enum.map(& &1.id)
      assert scoped.id in for_org and global.id in for_org

      for_other = Webhooks.audit_webhooks_for("token", "minted", other.id) |> Enum.map(& &1.id)
      assert global.id in for_other
      refute scoped.id in for_other

      # An event with NO org only reaches global subscriptions.
      no_org = Webhooks.audit_webhooks_for("token", "minted", nil) |> Enum.map(& &1.id)
      assert no_org == [global.id]
    end

    test "an audit webhook is NOT selected for content fan-out", %{org: org} do
      _a = sub(%{"audit_categories" => ["content_mutation"], "organization_id" => org.id})
      assert Webhooks.active_webhooks_for("production", "publish", "post") == []
    end
  end

  describe "Audit.emit → webhook bridge" do
    test "emit selects the matching subscription + builds the audit payload (via audit_targets)",
         %{org: org} do
      auth_sub = sub(%{"audit_categories" => ["auth"], "organization_id" => org.id})
      _token_sub = sub(%{"audit_categories" => ["token"], "organization_id" => org.id})

      {:ok, event} =
        Audit.emit(%{
          category: "auth",
          action: "sso_login",
          subject: "u1",
          metadata: %{"organization_id" => org.id, "provider" => "oidc"}
        })

      # The bridge fires inside emit (fire-and-forget); the SELECTION + PAYLOAD
      # it uses are exercised synchronously here.
      {webhooks, body} = Dispatcher.audit_targets(event)
      assert Enum.map(webhooks, & &1.id) == [auth_sub.id]

      payload = Jason.decode!(body)
      assert payload["kind"] == "audit_event"
      assert payload["category"] == "auth"
      assert payload["action"] == "sso_login"
      assert payload["organization_id"] == org.id
    end

    test "the emit bridge delivers a matching audit event through a durable audit row", %{
      org: org
    } do
      wh = sub(%{"audit_categories" => ["auth"], "organization_id" => org.id})

      {:ok, _event} =
        Audit.emit(%{
          category: "auth",
          action: "sso_login",
          subject: "u3",
          metadata: %{"organization_id" => org.id}
        })

      # The post-commit bridge fires the signed delivery through the same durable
      # state machine content webhooks use (source_kind "audit").
      assert_receive {:delivered, "https://sink.example/hook", body}, 2000
      assert Jason.decode!(body)["action"] == "sso_login"

      [d] = Repo.all(from d in Barkpark.Webhooks.Delivery, where: d.endpoint_id == ^wh.id)
      assert d.source_kind == "audit"
      assert d.status == "ok"
    end

    test "an event for another org yields no targets (no cross-tenant delivery)", %{org: org} do
      {:ok, other} = Tenancy.create_organization(%{slug: "nope", name: "Nope"})
      _other_sub = sub(%{"audit_categories" => ["auth"], "organization_id" => other.id})

      {:ok, event} =
        Audit.emit(%{
          category: "auth",
          action: "sso_login",
          subject: "u2",
          metadata: %{"organization_id" => org.id}
        })

      assert {[], _body} = Dispatcher.audit_targets(event)
    end
  end
end
