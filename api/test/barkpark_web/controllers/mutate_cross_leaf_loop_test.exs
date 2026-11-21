defmodule BarkparkWeb.MutateCrossLeafLoopTest do
  @moduledoc """
  task-3886eb786fc98923: a cross rule leaf carrying an `all`, `any` or `one`
  that is not a list (`{"all": null, "field": "a", "operator": "empty"}`, as a
  JSON generator can emit) passed `partition/1` as evaluable, and evaluating
  it looped forever: every save of that type spun a process. Such a rule is
  now unevaluable (no finding, a log line), and evaluation never loops.
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.CrossValidator

  @leaf %{"field" => "a", "operator" => "empty"}
  @shapes [
    {"all: null beside a leaf", %{"rule" => Map.put(@leaf, "all", nil)}, %{}},
    {"any: false beside a leaf", %{"rule" => Map.put(@leaf, "any", false)}, %{}},
    {"one: null beside a leaf", %{"rule" => Map.put(@leaf, "one", nil)}, %{}},
    {"the same, nested in an all list", %{"rule" => %{"all" => [Map.put(@leaf, "all", nil)]}},
     %{}},
    {"an item rule's leaf",
     %{"each" => "meny", "rule" => %{"all" => nil, "field" => "side", "operator" => "empty"}},
     %{"meny" => [%{"_key" => "k"}]}}
  ]

  defp schema(rule),
    do: %{
      "fields" => [%{"name" => "a"}, %{"name" => "meny"}],
      "cross_validations" => [Map.put(rule, "name", "r")]
    }

  # The call under a 1 s cap: on the old code it never returns.
  defp within_a_second(fun) do
    task = Task.async(fun)
    Task.yield(task, 1000) || Task.shutdown(task, :brutal_kill)
  end

  test "a leaf with a non-list all/any/one is unevaluable and findings returns" do
    for {name, rule, doc} <- @shapes do
      found = within_a_second(fn -> CrossValidator.findings(schema(rule), doc) end)

      assert found == {:ok, %{errors: [], warnings: []}},
             "#{name}: findings did not return in 1 s"

      reasons = for {_rule, reason} <- elem(CrossValidator.partition(schema(rule)), 1), do: reason
      assert reasons == ["an all/any/one list is empty or not a list"], name
    end
  end

  test "validate/2, which does not partition, returns too" do
    for {name, rule, doc} <- @shapes do
      returned = within_a_second(fn -> CrossValidator.validate(schema(rule), doc) end)
      assert match?({:ok, [_]}, returned), "#{name}: validate did not return"
    end
  end

  test "the banner's text is never blank and never a map" do
    assert CrossValidator.label(%{"title" => "T", "name" => "n"}) == "T"
    assert CrossValidator.label(%{"title" => "", "name" => "n"}) == "n"
    assert CrossValidator.label(%{}) == "cross-field rule"

    # A map name is dropped like a map title, so the banner's test id never interpolates a map.
    [v] =
      CrossValidator.violations(
        schema(%{"rule" => %{"field" => "a", "operator" => "non_empty"}})
        |> put_in(["cross_validations", Access.at(0), "name"], %{"nb" => "r"}),
        %{}
      )

    refute Map.has_key?(v, "name")
    assert CrossValidator.label(v) == "cross-field rule"
  end

  @tag timeout: 15_000
  test "a save of a type whose stored schema has such a leaf answers" do
    dataset = "xvloop_#{System.unique_integer([:positive])}"
    token = "barkpark-dev-token-xvloop-#{System.unique_integer([:positive])}"
    ws = Barkpark.Tenancy.get_default_workspace()
    proj = Barkpark.Tenancy.get_default_project()
    Auth.create_token(token, "dev", dataset, ["read", "write", "admin"], ws.id)
    {:ok, _} = Barkpark.Tenancy.create_dataset(proj, %{slug: dataset, name: dataset})
    type = "xvloop_#{System.unique_integer([:positive])}"

    {:ok, _} =
      Content.upsert_schema(
        %{
          "name" => type,
          "title" => "Loop",
          "fields" => [%{"name" => "a", "type" => "string"}],
          "cross_validations" => [
            %{
              "name" => "r",
              "level" => "error",
              "fields" => ["a"],
              "rule" => Map.put(@leaf, "all", nil)
            }
          ]
        },
        dataset,
        workspace_id: ws.id,
        project_id: proj.id
      )

    resp =
      scoped_conn()
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post(
        "/v1/data/mutate/#{dataset}",
        Jason.encode!(%{
          "mutations" => [
            %{
              "create" => %{
                "_id" => "l1",
                "_type" => type,
                "title" => "L",
                "content" => %{"a" => ""}
              }
            }
          ]
        })
      )

    assert resp.status == 200, resp.resp_body
  end
end
