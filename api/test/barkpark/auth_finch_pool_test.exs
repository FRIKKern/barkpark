defmodule Barkpark.AuthFinchPoolTest do
  @moduledoc """
  Felix W10 — task-felix-outbound-pool-isolation.

  The auth/login OUTBOUND path rides a DEDICATED Finch pool
  (`Barkpark.Auth.Finch`) instead of Req's global default (`Req.Finch`) so its
  connection budget is owned, tunable, and decoupled from the webhook/CDN
  storm traffic on the default pool. This is DEFENSE-IN-DEPTH, not a
  login-starvation crash-fix: Finch partitions connection slots per
  {scheme,host,port}, so cross-host storms cannot drain the IdP host's slots on
  the shared instance today. The pool bounds BEAM-global socket/FD pressure and
  deterministically isolates the same-host edge.

  Guards, most-load-bearing first:
    1. the pool is a live, usable Finch instance at runtime (fail-before: no
       such process exists — a routed call would exit);
    2. `child_specs/4` declares it UNCONDITIONALLY in the always-on tier;
    3. every one of the 5 auth-outbound clients routes to it.
  """
  use ExUnit.Case, async: true

  @auth_finch Barkpark.Auth.Finch

  # The 5 auth-outbound call sites that MUST route to the dedicated pool
  # (D54 boundary — note bokbasen nests under onixedit/, not plugins/bokbasen/).
  @routed_sources [
    "lib/barkpark/sso/oidc/http.ex",
    "lib/barkpark/sso/social/http.ex",
    "lib/barkpark/plugins/github/auth.ex",
    "lib/barkpark/plugins/indx/auth.ex",
    "lib/barkpark/plugins/onixedit/bokbasen/auth.ex"
  ]

  describe "the dedicated auth Finch pool at runtime" do
    test "Barkpark.Auth.Finch is a live, named process (started by the app)" do
      pid = Process.whereis(@auth_finch)
      assert is_pid(pid), "expected Barkpark.Auth.Finch to be started; got #{inspect(pid)}"
      assert Process.alive?(pid)
    end

    test "the pool is a usable Finch instance — a routed request returns a bounded error, never a raise" do
      # 127.0.0.1:1 is never listened on → deterministic, immediate econnrefused.
      # BEFORE the pool existed this call would EXIT (unknown Finch instance);
      # after, it flows through the pool and comes back as a plain {:error, _}.
      result = Req.get("http://127.0.0.1:1", finch: @auth_finch, retry: false)
      assert match?({:error, _}, result), "expected a bounded {:error, _}, got #{inspect(result)}"
    end
  end

  describe "supervision-tree wiring" do
    test "child_specs/4 declares {Finch, name: Barkpark.Auth.Finch} unconditionally" do
      # Empty plugin/sync/self-update tiers → the auth pool must STILL be present
      # (it is in the always-on base list, not gated behind any subsystem).
      specs = Barkpark.Application.child_specs([], [repo: Barkpark.Repo], [], [])

      finch_spec =
        Enum.find(specs, fn
          {Finch, opts} when is_list(opts) -> Keyword.get(opts, :name) == @auth_finch
          _ -> false
        end)

      assert finch_spec, "Barkpark.Auth.Finch child spec missing from child_specs/4"
      {Finch, opts} = finch_spec
      assert %{default: pool_opts} = Keyword.fetch!(opts, :pools)
      assert Keyword.get(pool_opts, :size) == 10
      assert Keyword.get(pool_opts, :count) == 1
    end
  end

  describe "call-site routing (all 5 auth-outbound clients)" do
    for source <- @routed_sources do
      test "#{source} routes outbound through Barkpark.Auth.Finch" do
        body = File.read!(unquote(source))

        assert body =~ "finch: Barkpark.Auth.Finch",
               "#{unquote(source)} must pass `finch: Barkpark.Auth.Finch` on its outbound Req call"
      end
    end
  end
end
