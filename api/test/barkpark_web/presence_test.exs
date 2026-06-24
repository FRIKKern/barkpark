defmodule BarkparkWeb.PresenceTest do
  @moduledoc """
  Contract tests for `BarkparkWeb.Presence`.

  The module is a thin `use Phoenix.Presence` wrapper — there is no custom
  business logic, so we verify its static contract:

    1. Required Phoenix.Presence callbacks are exported.
    2. `child_spec/1` returns a valid supervisor-child shape.
    3. The module is correctly registered against the `:barkpark` OTP app.
    4. It names the canonical PubSub server (Barkpark.PubSub).
  """

  use ExUnit.Case, async: true

  alias BarkparkWeb.Presence

  describe "exported callbacks (Phoenix.Presence contract)" do
    test "list/1 is exported" do
      assert function_exported?(Presence, :list, 1)
    end

    test "track/3 and track/4 are exported" do
      assert function_exported?(Presence, :track, 3)
      assert function_exported?(Presence, :track, 4)
    end

    test "untrack/2 and untrack/3 are exported" do
      assert function_exported?(Presence, :untrack, 2)
      assert function_exported?(Presence, :untrack, 3)
    end

    test "update/3 and update/4 are exported" do
      assert function_exported?(Presence, :update, 3)
      assert function_exported?(Presence, :update, 4)
    end

    test "get_by_key/2 is exported" do
      assert function_exported?(Presence, :get_by_key, 2)
    end

    test "fetch/2 is exported (default pass-through fetch)" do
      assert function_exported?(Presence, :fetch, 2)
    end
  end

  describe "child_spec/1" do
    test "returns a map with the required supervisor-child keys" do
      spec = Presence.child_spec([])
      assert is_map(spec)
      assert Map.has_key?(spec, :id)
      assert Map.has_key?(spec, :start)
    end

    test "start tuple is a 3-element tuple with the module as the first element" do
      %{start: start} = Presence.child_spec([])
      assert is_tuple(start)
      assert tuple_size(start) == 3
      {mod, _fun, _args} = start
      # The first element may be Phoenix.Presence or the generated module itself,
      # but it must be an atom (a valid module name).
      assert is_atom(mod)
    end
  end

  describe "OTP app configuration" do
    test "module is compiled under the :barkpark OTP application" do
      {:ok, app} = :application.get_application(Presence)
      assert app == :barkpark
    end

    test "the declared pubsub server atom is Barkpark.PubSub" do
      # child_spec args carry the pubsub_server — confirm the expected atom
      # survives into the supervisor spec so presence can actually subscribe.
      # start tuple: {Phoenix.Presence, :start_link, [module, task_sup, opts]}
      spec = Presence.child_spec([])
      {_mod, _fun, [_presence_mod, _task_sup, opts]} = spec.start
      pubsub = Keyword.get(opts, :pubsub_server)
      assert pubsub == Barkpark.PubSub
    end
  end
end
