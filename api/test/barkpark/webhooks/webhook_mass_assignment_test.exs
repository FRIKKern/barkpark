defmodule Barkpark.Webhooks.WebhookMassAssignmentTest do
  @moduledoc """
  Cross-tenant mass-assignment guard for the webhook write path.

  The scope a webhook is owned by is SERVER-AUTHORITATIVE: it comes from the
  authenticated request scope (`ScopeHelpers.scope_opts`), never from the
  request body. A client that smuggles a foreign `workspace_id`/`project_id`
  (or `dataset_id`) into create/update attrs must NOT be able to move the hook
  into another tenant (cross-tenant event exfiltration), and the signing
  `secret`/rotation fields must NOT be client-castable on update (rotation is
  only via `rotate_secret/3`).
  """
  use Barkpark.DataCase, async: true

  import Barkpark.TenancyFixtures

  alias Barkpark.Repo
  alias Barkpark.Webhooks
  alias Barkpark.Webhooks.Webhook

  @dataset "test"

  defp base_attrs(overrides) do
    Map.merge(
      %{
        "name" => "hook",
        "url" => "http://example.com/hook",
        "dataset" => @dataset
      },
      overrides
    )
  end

  describe "create_webhook/2 scope authority" do
    test "a foreign workspace_id in attrs is IGNORED — the opts scope wins" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_foreign = create_workspace!()

      {:ok, wh} =
        Webhooks.create_webhook(
          base_attrs(%{
            "workspace_id" => ws_foreign.id,
            "project_id" => Ecto.UUID.generate()
          }),
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      assert wh.workspace_id == ws_a.id
      assert wh.project_id == proj_a.id
      refute wh.workspace_id == ws_foreign.id
    end

    test "an atom-keyed foreign workspace_id is also dropped" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_foreign = create_workspace!()

      {:ok, wh} =
        Webhooks.create_webhook(
          %{
            "name" => "hook",
            "url" => "http://example.com/hook",
            "dataset" => @dataset,
            workspace_id: ws_foreign.id
          },
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      assert wh.workspace_id == ws_a.id
    end
  end

  describe "update_webhook/2 scope + secret immutability" do
    setup do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)
      ws_b = create_workspace!()

      {:ok, wh} =
        Webhooks.create_webhook(
          base_attrs(%{"secret" => "s1"}),
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      %{ws_a: ws_a, proj_a: proj_a, ws_b: ws_b, wh: wh}
    end

    test "carrying a foreign workspace_id leaves the hook in its original scope", %{
      ws_a: ws_a,
      ws_b: ws_b,
      wh: wh
    } do
      {:ok, updated} =
        Webhooks.update_webhook(wh, %{
          "name" => "renamed",
          "workspace_id" => ws_b.id,
          "project_id" => Ecto.UUID.generate()
        })

      # The rename applied; the scope did NOT move.
      assert updated.name == "renamed"
      assert updated.workspace_id == ws_a.id
      refute updated.workspace_id == ws_b.id

      # Re-read from the DB to be sure it was persisted, not just in the struct.
      reloaded = Repo.get!(Webhook, wh.id)
      assert reloaded.workspace_id == ws_a.id
    end

    test "carrying secret/previous_secret does NOT change the stored secrets", %{wh: wh} do
      {:ok, updated} =
        Webhooks.update_webhook(wh, %{
          "name" => "renamed",
          "secret" => "s2-attacker",
          "previous_secret" => "reinstated-old",
          "previous_secret_expires_at" => ~U[2099-01-01 00:00:00.000000Z]
        })

      assert updated.name == "renamed"
      assert updated.secret == "s1"
      assert is_nil(updated.previous_secret)
      assert is_nil(updated.previous_secret_expires_at)
    end
  end

  describe "rotate_secret/3 still establishes the previous-secret window" do
    test "moves the current secret to previous with a future expiry" do
      ws_a = create_workspace!()
      proj_a = create_project!(ws_a)

      {:ok, wh} =
        Webhooks.create_webhook(
          base_attrs(%{"secret" => "s1"}),
          workspace_id: ws_a.id,
          project_id: proj_a.id
        )

      {:ok, rotated} = Webhooks.rotate_secret(wh, "s2")

      assert rotated.secret == "s2"
      assert rotated.previous_secret == "s1"
      assert DateTime.compare(rotated.previous_secret_expires_at, DateTime.utc_now()) == :gt
    end
  end
end
