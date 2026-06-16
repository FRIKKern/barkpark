# Seed the "docs" dataset schemas by copying production's catalog, adding the
# paper `related` arrayOf(reference) field so wikilink relationships become
# content-graph edges. Run on prod: MIX_ENV=prod mix run --no-start <this>
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Barkpark.Repo.start_link()

alias Barkpark.Content

ws = "ec0a6b95-8d6c-437a-aa00-770c005c2e4a"
proj = "6a9302b2-fe12-4cd5-b276-58374b8549e6"
opts = [workspace_id: ws, project_id: proj]

to_attrs = fn s ->
  %{
    "name" => s.name,
    "title" => s.title,
    "icon" => s.icon,
    "visibility" => s.visibility,
    "fields" => s.fields,
    "actions" => s.actions,
    "groups" => s.groups,
    "desk_groups" => s.desk_groups,
    "list_preview" => s.list_preview,
    "initial_values" => s.initial_values,
    "cross_validations" => s.cross_validations,
    "layout" => s.layout,
    "prefill" => s.prefill,
    "cors_origins" => s.cors_origins
  }
end

related = %{
  "name" => "related",
  "title" => "Related",
  "type" => "arrayOf",
  "ordered" => false,
  "of" => %{"type" => "reference", "refType" => "paper"}
}

src = Content.list_schemas("production", opts)
IO.puts("source production schemas: #{length(src)}")

results =
  for s <- src do
    attrs = to_attrs.(s)

    attrs =
      if s.name == "paper" do
        has? = Enum.any?(s.fields, fn f -> (f["name"] || f[:name]) == "related" end)
        if has?, do: attrs, else: Map.put(attrs, "fields", s.fields ++ [related])
      else
        attrs
      end

    case Content.upsert_schema(attrs, "docs", opts) do
      {:ok, sd} -> {:ok, sd.name}
      {:error, cs} -> {:error, s.name, inspect(cs.errors)}
    end
  end

ok = Enum.count(results, &match?({:ok, _}, &1))
errs = Enum.filter(results, &match?({:error, _, _}, &1))
IO.puts("seeded #{ok}/#{length(src)} schemas into docs")
if errs != [], do: IO.inspect(errs, label: "ERRORS", limit: :infinity)

# confirm the docs paper schema now carries `related`
case Content.get_schema("paper", "docs", opts) do
  {:ok, p} ->
    names = Enum.map(p.fields, fn f -> f["name"] || f[:name] end)
    IO.puts("docs paper fields: #{inspect(names)}")

  other ->
    IO.inspect(other, label: "docs paper get_schema")
end
