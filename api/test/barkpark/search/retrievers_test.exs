defmodule Barkpark.Search.RetrieversTest do
  @moduledoc """
  The engine-neutral retriever SEAM: `Barkpark.Search.Retrievers.resolve/1`
  maps a surface config's `engine` to the module that fulfils the
  `Barkpark.Search.Retriever` behaviour. Postgres is the built-in default;
  plugins register additional engines via
  `config :barkpark, :search_retrievers, %{"indx" => MyRetriever}`. Unknown
  engines fall back to the Postgres default so a misconfigured engine never
  takes a surface dark.
  """
  use ExUnit.Case, async: false

  alias Barkpark.Search.{DocumentsRetriever, Retrievers}

  defmodule FakeRetriever do
    @behaviour Barkpark.Search.Retriever
    @impl true
    def search(_scope, _parsed, _config, _opts), do: {[%{id: "FAKE"}], 1}
  end

  setup do
    prior = Application.get_env(:barkpark, :search_retrievers)
    Application.put_env(:barkpark, :search_retrievers, %{"fake" => FakeRetriever})

    on_exit(fn ->
      if prior do
        Application.put_env(:barkpark, :search_retrievers, prior)
      else
        Application.delete_env(:barkpark, :search_retrievers)
      end
    end)

    :ok
  end

  test "resolve/1 returns the Postgres retriever when config carries no engine" do
    assert Retrievers.resolve(%{}) == DocumentsRetriever
  end

  test "resolve/1 returns the Postgres retriever for engine \"postgres\"" do
    assert Retrievers.resolve(%{"engine" => "postgres"}) == DocumentsRetriever
  end

  test "resolve/1 returns a registered module for a custom engine" do
    assert Retrievers.resolve(%{"engine" => "fake"}) == FakeRetriever
  end

  test "resolve/1 falls back to the Postgres retriever for an unknown engine" do
    assert Retrievers.resolve(%{"engine" => "nope-not-registered"}) == DocumentsRetriever
  end
end
