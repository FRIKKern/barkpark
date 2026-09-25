defmodule Barkpark.Plugins.FormsContractTest do
  @moduledoc """
  c0 of task-71082f5541c13b53: the `form_submission` / `form_endpoint`
  contract is registered (schemas + a pre-write check on the writer doors),
  and an unknown or oversized payload is refused without any row being
  stored.
  """
  use Barkpark.DataCase, async: false

  import Barkpark.TenancyFixtures
  import Ecto.Query, only: [from: 2]

  alias Barkpark.Content
  alias Barkpark.Content.Document
  alias Barkpark.Plugins.Forms
  alias Barkpark.Plugins.Forms.Contract
  alias Barkpark.Repo

  @dataset "test"

  defp rows(type, ws) do
    from(d in Document, where: d.type == ^type and d.workspace_id == ^ws.id) |> Repo.all()
  end

  defp valid_content(overrides \\ %{}) do
    Map.merge(
      Contract.new_submission(%{
        site: "my-blog",
        fields: %{"name" => "Kari", "message" => "Hei"},
        source: %{origin: "https://my-blog.example.com"}
      }),
      overrides
    )
  end

  describe "registration" do
    test "both types register as PRIVATE schemas" do
      schemas = Forms.register_schemas(dataset: @dataset)
      assert Enum.map(schemas, & &1.name) == ["form_submission", "form_endpoint"]
      assert Enum.all?(schemas, &(&1.visibility == "private"))
    end

    test "the contract check is declared as a pre-write :check" do
      assert {:check, Contract, :validate} in Forms.pre_write_transforms()
    end
  end

  describe "the submission contract (pure)" do
    test "a built submission carries every contract field and validates" do
      c = valid_content()

      for key <- ~w(site endpoint_id received_at fields state spam spam_reasons source),
          do: assert(Map.has_key?(c, key), "missing #{key}")

      assert c["state"] == "new"
      assert c["spam"] == "clean"
      assert :ok == Contract.validate("form_submission", %{"content" => c})
    end

    test "state and spam are closed sets; site and received_at are shaped" do
      for {k, bad} <- [
            {"state", "archived"},
            {"spam", "maybe"},
            {"site", "Not A Slug"},
            {"received_at", "yesterday"},
            {"fields", %{}},
            {"fields", %{"x" => %{"nested" => "no"}}}
          ] do
        result = Contract.validate("form_submission", %{"content" => valid_content(%{k => bad})})

        assert match?({:error, {:schema_validation_failed, %{^k => _}}}, result),
               "#{k}=#{inspect(bad)} was not refused on #{k}: #{inspect(result)}"
      end
    end

    test "an endpoint needs a site, an enabled flag, bare origins and a field allowlist" do
      ok = %{
        "site" => "my-blog",
        "enabled" => true,
        "allowed_origins" => ["https://my-blog.example.com"],
        "fields" => ["name", "message"]
      }

      assert :ok == Contract.validate("form_endpoint", %{"content" => ok})

      for {k, bad} <- [
            {"allowed_origins", []},
            {"allowed_origins", ["https://x.example.com/path"]},
            {"allowed_origins", ["*"]},
            {"fields", []},
            {"fields", ["bp_hp"]},
            {"enabled", "yes"}
          ] do
        result = Contract.validate("form_endpoint", %{"content" => Map.put(ok, k, bad)})

        assert match?({:error, {:schema_validation_failed, %{^k => _}}}, result),
               "#{k}=#{inspect(bad)} was not refused on #{k}: #{inspect(result)}"
      end
    end

    test "other types pass through untouched" do
      assert :ok == Contract.validate("post", %{"content" => %{"anything" => 1}})
    end
  end

  describe "sanitize_fields/2 refuses whole, never trims" do
    test "an unknown field is refused, naming it" do
      assert {:error, {:unknown_fields, ["evil"]}} =
               Contract.sanitize_fields(%{"name" => "a", "evil" => "b"}, ["name"])
    end

    test "an oversized value is refused, not truncated" do
      big = String.duplicate("x", Contract.limits().max_value_bytes + 1)

      assert {:error, {:too_large, _}} =
               Contract.sanitize_fields(%{"message" => big}, ["message"])
    end

    test "too many fields and too many total bytes are refused" do
      names = for i <- 1..(Contract.limits().max_fields + 1), do: "f#{i}"
      raw = Map.new(names, &{&1, "v"})
      assert {:error, {:too_large, _}} = Contract.sanitize_fields(raw, names)

      names = for i <- 1..8, do: "f#{i}"
      raw = Map.new(names, &{&1, String.duplicate("y", 4_500)})
      assert {:error, {:too_large, _}} = Contract.sanitize_fields(raw, names)
    end

    test "non-string values are refused; blanks are omitted" do
      assert {:error, {:invalid, _}} = Contract.sanitize_fields(%{"n" => %{"a" => 1}}, ["n"])
      assert {:error, {:invalid, _}} = Contract.sanitize_fields(%{"n" => ""}, ["n"])

      assert {:ok, %{"n" => "a", "tags" => ["x"]}} =
               Contract.sanitize_fields(%{"n" => "a", "m" => " ", "tags" => ["x", ""]}, [
                 "n",
                 "m",
                 "tags"
               ])
    end
  end

  describe "the writer door enforces the contract (nothing partial is stored)" do
    setup do
      ws = create_workspace!()
      proj = create_project!(ws)
      %{ws: ws, proj: proj, scope: [workspace_id: ws.id, project_id: proj.id]}
    end

    test "a valid submission is stored", %{ws: ws, scope: scope} do
      assert {:ok, _} =
               Content.create_document(
                 "form_submission",
                 %{"title" => "t", "content" => valid_content()},
                 @dataset,
                 scope
               )

      assert [_] = rows("form_submission", ws)
    end

    test "an invalid submission written through the GENERIC door is refused and stores nothing",
         %{ws: ws, scope: scope} do
      bad = valid_content(%{"state" => "archived", "fields" => %{"x" => %{"deep" => 1}}})

      assert {:error, {:schema_validation_failed, errors}} =
               Content.create_document(
                 "form_submission",
                 %{"title" => "t", "content" => bad},
                 @dataset,
                 scope
               )

      assert Map.has_key?(errors, "state")
      assert Map.has_key?(errors, "fields")
      assert [] == rows("form_submission", ws)
    end

    test "an oversized field map through the generic door stores nothing", %{ws: ws, scope: scope} do
      big = String.duplicate("x", Contract.limits().max_value_bytes + 1)

      assert {:error, {:schema_validation_failed, %{"fields" => _}}} =
               Content.create_document(
                 "form_submission",
                 %{"title" => "t", "content" => valid_content(%{"fields" => %{"m" => big}})},
                 @dataset,
                 scope
               )

      assert [] == rows("form_submission", ws)
    end

    test "an upsert that breaks a stored submission is refused and leaves it intact",
         %{ws: ws, scope: scope} do
      {:ok, doc} =
        Content.create_document(
          "form_submission",
          %{"title" => "t", "content" => valid_content()},
          @dataset,
          scope
        )

      assert {:error, {:schema_validation_failed, %{"state" => _}}} =
               Content.upsert_document(
                 "form_submission",
                 %{
                   "doc_id" => doc.doc_id,
                   "title" => "t",
                   "content" => valid_content(%{"state" => "deleted"})
                 },
                 @dataset,
                 scope
               )

      assert [row] = rows("form_submission", ws)
      assert row.content["state"] == "new"
    end
  end
end
