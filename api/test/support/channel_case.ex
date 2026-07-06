defmodule BarkparkWeb.ChannelCase do
  @moduledoc """
  Test case for Phoenix channel tests (PulseChannel is the first tenant).

  Standard generator shape: imports `Phoenix.ChannelTest` against the app
  endpoint and checks out the SQL sandbox per test.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import BarkparkWeb.ChannelCase

      @endpoint BarkparkWeb.Endpoint
    end
  end

  setup tags do
    Barkpark.DataCase.setup_sandbox(tags)
    :ok
  end
end
