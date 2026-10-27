defmodule Barkpark.Groq.ArityTest do
  @moduledoc """
  task-3f83a5527aa535fa: a call with the wrong number of arguments is a parse
  error worded as Sanity words it, function by function. Every expected text
  below was read off Sanity's query API (ecu57yeh, e2e-local, 27 Oct).
  """
  use ExUnit.Case, async: true

  alias Barkpark.Groq.Parser

  defp error(query) do
    result = Parser.parse(query)
    assert match?({:error, %{description: _}}, result), query
    {:error, %{description: description}} = result
    description
  end

  test "most functions: Incorrect number of arguments to function \"name\"" do
    for {query, name} <- [
          {"count()", "count"},
          {"count(1, 2)", "count"},
          {"lower(1, 2)", "lower"},
          {"round()", "round"},
          {"round(1, 2, 3)", "round"},
          {"identity(1)", "identity"},
          {"now(1)", "now"},
          {"boost(1)", "boost"},
          {"geo::latLng(1)", "latLng"},
          {~s|string::split("a")|, "split"},
          {"array::join(1, 2, 3)", "join"},
          {"math::sum()", "sum"},
          {"pt::text()", "text"},
          {"sanity::projectId(1)", "projectId"},
          {"sanity::dataset(1)", "dataset"}
        ] do
      assert error(query) == ~s|Incorrect number of arguments to function "#{name}"|, query
    end
  end

  test "the functions Sanity words its own way" do
    for {query, want} <- [
          {"defined()", "single argument expected"},
          {"defined(1, 2)", "single argument expected"},
          {"media::aspect(1)", "two arguments expected"},
          {"sanity::versionOf()", "one argument expected"},
          {"sanity::partOfRelease(1, 2)", "one argument expected"},
          {"documents::get()", "one argument expected"},
          {"documents::get(1, 2)", "one argument expected"},
          {"releases::all(1)", "zero arguments expected"},
          {"user::attributes(1)", "zero arguments expected"},
          {"references()", "arguments expected"},
          {"diff::changedAny()", "three arguments expected"},
          {"*[_type == 'post'] | order()", "argument expected"},
          {"*[_type == 'post'] | score()", "argument expected"}
        ] do
      assert error(query) == want, query
    end
  end
end
