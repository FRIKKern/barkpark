defmodule Barkpark.Plugins.Indx.SeamDispatchTest do
  @moduledoc """
  The document-search SEAM resolves engine `"indx"` to
  `Barkpark.Plugins.Indx.Retriever`.

  Two registration paths must both land the same module:

    * the static `config :barkpark, :search_retrievers` entry in
      `config/config.exs` (inert until a surface opts in), and
    * the plugin's boot-time `register_workers/1`, which re-asserts the
      mapping via `Application.put_env/3`.

  Postgres stays the default for every other engine — the additive
  invariant.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Search.{DocumentsRetriever, Retrievers}

  test "resolve/1 routes engine \"indx\" to the Indx retriever (static config)" do
    assert Retrievers.resolve(%{"engine" => "indx"}) == Barkpark.Plugins.Indx.Retriever
  end

  test "the plugin's register_workers/1 re-asserts the indx engine mapping" do
    prior = Application.get_env(:barkpark, :search_retrievers)

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, :search_retrievers, prior)
      else
        Application.delete_env(:barkpark, :search_retrievers)
      end
    end)

    # Wipe the mapping, then prove register_workers/1 restores it and
    # contributes the Auth GenServer child.
    Application.put_env(:barkpark, :search_retrievers, %{})

    children = Barkpark.Plugins.Indx.register_workers(%{})

    assert Barkpark.Plugins.Indx.Auth in children
    assert Retrievers.resolve(%{"engine" => "indx"}) == Barkpark.Plugins.Indx.Retriever
  end

  test "the default + unknown engines still fall back to Postgres" do
    assert Retrievers.resolve(%{}) == DocumentsRetriever
    assert Retrievers.resolve(%{"engine" => "postgres"}) == DocumentsRetriever
    assert Retrievers.resolve(%{"engine" => "no-such-engine"}) == DocumentsRetriever
  end
end
