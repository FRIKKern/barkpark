defmodule Barkpark.Auth.TokenExpiryTest do
  @moduledoc """
  task-a0f8cfd7f4800236 — `Barkpark.Auth.TokenExpiry` and the in-process
  `Auth.create_token/6` door. The HTTP routes are proven in
  `token_expiry_mint_test.exs`; this file pins the policy table itself.

  async: false — the default arms put_env `:token_default_expiry_days`.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Audit.Event
  alias Barkpark.Auth
  alias Barkpark.Auth.{ApiToken, TokenExpiry}
  alias Barkpark.Repo

  @day 86_400

  setup do
    prior = Application.get_env(:barkpark, :token_default_expiry_days)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:barkpark, :token_default_expiry_days, prior),
        else: Application.delete_env(:barkpark, :token_default_expiry_days)
    end)

    :ok
  end

  defp configure_default(map), do: Application.put_env(:barkpark, :token_default_expiry_days, map)
  defp raw, do: "exp-unit-#{System.unique_integer([:positive])}"
  defp now, do: ~U[2026-09-24 12:00:00Z]

  describe "the policy table" do
    test "max ages: api 365, share 365, app none" do
      assert TokenExpiry.max_age_days(:api) == 365
      assert TokenExpiry.max_age_days(:share) == 365
      assert TokenExpiry.max_age_days(:app) == nil
    end

    test "the SHIPPED config is nil for every kind" do
      assert Application.get_env(:barkpark, :token_default_expiry_days) == %{
               api: nil,
               share: nil
             }

      assert TokenExpiry.default_days(:api) == nil
      assert TokenExpiry.default_days(:share) == nil
    end

    test "class from permissions: public-read → share, else api" do
      assert TokenExpiry.class_for_permissions(["public-read"]) == :share
      assert TokenExpiry.class_for_permissions(["read", "public-read"]) == :share
      assert TokenExpiry.class_for_permissions(["read"]) == :api
      assert TokenExpiry.class_for_permissions(["read", "write", "admin"]) == :api
    end
  end

  describe "resolve/3" do
    test "no request + no default → no expiry (today's mint)" do
      assert {:ok, nil} = TokenExpiry.resolve(:api, nil, now: now())
      assert {:ok, nil} = TokenExpiry.resolve(:share, nil, now: now())
    end

    test "no request + a configured default → now + default" do
      configure_default(%{api: 90, share: 14})
      assert {:ok, at} = TokenExpiry.resolve(:api, nil, now: now())
      assert DateTime.diff(at, now()) == 90 * @day
      assert {:ok, at} = TokenExpiry.resolve(:share, nil, now: now())
      assert DateTime.diff(at, now()) == 14 * @day
    end

    test "a path's own fallback wins over the configured default" do
      configure_default(%{api: 90, share: 14})
      assert {:ok, at} = TokenExpiry.resolve(:api, nil, now: now(), fallback: 3600)
      assert DateTime.diff(at, now()) == 3600
    end

    test "a requested expiry AT the max is admitted unchanged" do
      at = DateTime.add(now(), 365 * @day)
      assert {:ok, ^at} = TokenExpiry.resolve(:share, at, now: now())
    end

    test "a requested expiry ONE SECOND past the max is refused naming the max" do
      assert {:error, {:expiry_exceeds_max, :share, 365}} =
               TokenExpiry.resolve(:share, DateTime.add(now(), 365 * @day + 1), now: now())

      assert {:error, {:expiry_exceeds_max, :api, 365}} =
               TokenExpiry.resolve(:api, DateTime.add(now(), 365 * @day + 1), now: now())
    end

    test "a past or present expiry is refused" do
      assert {:error, :expiry_not_in_future} = TokenExpiry.resolve(:api, now(), now: now())
    end

    test ":no_expiry is admin-only" do
      assert {:ok, nil} = TokenExpiry.resolve(:api, :no_expiry, admin?: true)
      assert {:error, :no_expiry_requires_admin} = TokenExpiry.resolve(:api, :no_expiry, [])
    end

    test "app tokens: no max, no default" do
      configure_default(%{api: 90, share: 14})
      assert {:ok, nil} = TokenExpiry.resolve(:app, nil, [])
      far = DateTime.add(now(), 3650 * @day)
      assert {:ok, ^far} = TokenExpiry.resolve(:app, far, [])
    end

    test "a configured default over the kind's max raises (misconfiguration)" do
      configure_default(%{api: nil, share: 366})

      assert_raise ArgumentError, ~r/above the share max age of 365 days/, fn ->
        TokenExpiry.resolve(:share, nil, [])
      end
    end

    test "message/1 names the max" do
      assert TokenExpiry.message({:expiry_exceeds_max, :api, 365}) =~ "365 days"
    end
  end

  describe "Auth.create_token/6" do
    test "opts-less: unchanged — no expiry while the default is nil" do
      {:ok, tok} = Auth.create_token(raw(), "plain", "production", ["read"])
      assert tok.expires_at == nil
    end

    test "a configured default lands on NEW rows only" do
      {:ok, old} = Auth.create_token(raw(), "old", "production", ["read"])
      configure_default(%{api: 90, share: nil})
      {:ok, new} = Auth.create_token(raw(), "new", "production", ["read"])

      assert_in_delta DateTime.diff(new.expires_at, DateTime.utc_now()) / @day, 90, 0.01
      assert Repo.get!(ApiToken, old.id).expires_at == nil
    end

    test "an over-max request writes no row" do
      before = Repo.aggregate(ApiToken, :count)
      at = DateTime.add(DateTime.utc_now(), 366 * @day)

      assert {:error, {:expiry_exceeds_max, :share, 365}} =
               Auth.create_token(raw(), "x", "production", ["public-read"], nil, expires_at: at)

      assert Repo.aggregate(ApiToken, :count) == before
    end

    test ":no_expiry: an admin-permission actor mints + audits; any other actor is refused" do
      {:ok, admin} = Auth.create_token(raw(), "adm", "production", ["read", "admin"])
      {:ok, plain} = Auth.create_token(raw(), "pln", "production", ["read", "write"])

      assert {:ok, tok} =
               Auth.create_token(raw(), "forever", "production", ["read"], nil,
                 expires_at: :no_expiry,
                 actor: admin
               )

      assert tok.expires_at == nil

      assert [%Event{actor_id: actor_id, metadata: %{"kind" => "api"}}] =
               Repo.all(
                 from(e in Event,
                   where: e.action == "token_no_expiry_opt_out" and e.subject == ^tok.id
                 )
               )

      assert actor_id == admin.id

      for actor <- [plain, nil] do
        assert {:error, :no_expiry_requires_admin} =
                 Auth.create_token(raw(), "nope", "production", ["read"], nil,
                   expires_at: :no_expiry,
                   actor: actor
                 )
      end
    end
  end
end
