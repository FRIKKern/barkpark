defmodule BarkparkWeb.Plugs.RequireTokenOrMemberSessionTest do
  @moduledoc """
  task-cc6ad07a8aa36338 — an API token on the scoped editor streams must meet
  exactly what `:require_token` asks of it. The gate runs its own copy of that
  chain (`token_chain/0`); this fails the moment router.ex's
  `pipeline :require_token` gains, loses or reorders a plug without it.
  """
  use ExUnit.Case, async: true

  alias BarkparkWeb.Plugs.RequireTokenOrMemberSession

  @router Path.expand("../../../lib/barkpark_web/router.ex", __DIR__)

  test "the token chain is router.ex's pipeline :require_token, plug for plug" do
    [_, body] =
      Regex.run(~r/\n  pipeline :require_token do\n(.*?)\n  end\n/s, File.read!(@router))

    plugs =
      ~r/^\s*plug\(([A-Za-z0-9_.]+)/m
      |> Regex.scan(body, capture: :all_but_first)
      |> Enum.map(fn [mod] -> Module.concat([mod]) end)

    assert plugs == RequireTokenOrMemberSession.token_chain()
  end
end
