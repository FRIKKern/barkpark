defmodule BarkparkWeb.MutateCrossLeafLoopTest do
  @moduledoc """
  task-3886eb786fc98923: a cross rule leaf carrying an `all`, `any` or `one`
  with no list to run (`{"all": null, "field": "a", "operator": "empty"}`, as
  a JSON generator can emit) looped forever when evaluated: every save of
  that type spun a process. A null combinator now reads as absent, so that
  rule is the plain leaf it looks like; `false` there is unevaluable. A rule
  that answered before answers the same (`{"all": [..], "any": null}` still
  refuses).
  """
  use BarkparkWeb.ConnCase, async: false

  alias Barkpark.Auth
  alias Barkpark.Content
  alias Barkpark.Content.CrossValidator

  @leaf %{"field" => "a", "operator" => "empty"}
  @good %{"field" => "a", "operator" => "non_empty"}

  # {name, rule, a doc it holds for, a doc it breaks}
  @null_leaves [
    {"all: null beside a leaf", %{"rule" => Map.put(@leaf, "all", nil)}, %{}, %{"a" => "x"}},
    {"one: null beside a leaf", %{"rule" => Map.put(@leaf, "one", nil)}, %{}, %{"a" => "x"}},
    {"the same, nested in an all list", %{"rule" => %{"all" => [Map.put(@leaf, "all", nil)]}},
     %{}, %{"a" => "x"}},
    {"an item rule's leaf",
     %{"each" => "meny", "rule" => %{"all" => nil, "field" => "side", "operator" => "empty"}},
     %{"meny" => [%{"_key" => "k"}]}, %{"meny" => [%{"_key" => "k", "side" => "x"}]}}
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

  defp error_count(rule, doc) do
    case within_a_second(fn -> CrossValidator.findings(schema(rule), doc) end) do
      {:ok, %{errors: errors}} -> length(errors)
      other -> {:no_answer, other}
    end
  end

  test "a null all/any/one beside a leaf reads as absent: the leaf is evaluated, in 1 s" do
    for {name, rule, holds, breaks} <- @null_leaves do
      assert error_count(rule, holds) == 0, "#{name}: holds"
      assert error_count(rule, breaks) == 1, "#{name}: breaks"
      assert elem(CrossValidator.partition(schema(rule)), 1) == [], name
    end
  end

  test "a null combinator beside a list keeps the rule it was: it still refuses" do
    for {name, body} <- [
          {"all: [good] + any: null", %{"all" => [@good], "any" => nil}},
          {"any: [good] + all: null + one: null", %{"any" => [@good], "all" => nil, "one" => nil}}
        ] do
      assert error_count(%{"rule" => body}, %{}) == 1, "#{name}: refuses"
      assert error_count(%{"rule" => body}, %{"a" => "x"}) == 0, "#{name}: holds"
    end
  end

  test "false beside a leaf is unevaluable, and validate/2 skips it as violations/2 does" do
    rule = %{"rule" => Map.put(@leaf, "any", false)}
    assert error_count(rule, %{"a" => "x"}) == 0

    reasons = for {_rule, reason} <- elem(CrossValidator.partition(schema(rule)), 1), do: reason
    assert reasons == ["an all/any/one is not a list"]

    returned = within_a_second(fn -> CrossValidator.validate(schema(rule), %{"a" => "x"}) end)
    assert returned == {:ok, []}
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
