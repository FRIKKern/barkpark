# Prod-shape race: two first upserts of one schema name, two REAL concurrent
# POST /v1/schemas/:ds requests against a real listener, no Ecto sandbox
# (task-3748d052b83a9a2e). Not an ExUnit test: the sandbox serializes it.
#
#   cd api && MIX_TEST_PARTITION=race MIX_ENV=test mix test test/barkpark/content/schema_upsert_converge_test.exs  # creates the DB
#   cd api && RACE_N=60 MIX_TEST_PARTITION=race MIX_ENV=test mix run --no-start ../scripts/races/schema_first_upsert.exs
#
# Prints the status counts and up to 5 non-2xx bodies; deletes its own
# dataset's schemas at the end. Listens on 127.0.0.1:4799.
repo_cfg = Application.get_env(:barkpark, Barkpark.Repo)
Application.put_env(:barkpark, Barkpark.Repo, Keyword.merge(repo_cfg, pool: DBConnection.ConnectionPool, pool_size: 20))
# The per-token write budget (60/min) is not what is under test.
Application.put_env(:barkpark, :rate_limits, Keyword.merge(Application.get_env(:barkpark, :rate_limits, []), write_per_minute: 1_000_000, read_per_minute: 1_000_000))
# A REAL listener, so the loser's status/body is what a client sees, not what
# Phoenix.ConnTest re-raises.
ep = Application.get_env(:barkpark, BarkparkWeb.Endpoint)
Application.put_env(:barkpark, BarkparkWeb.Endpoint, Keyword.merge(ep, server: true, http: [ip: {127, 0, 0, 1}, port: 4799]))
{:ok, _} = Application.ensure_all_started(:barkpark)
{:ok, _} = Application.ensure_all_started(:req)

n = String.to_integer(System.get_env("RACE_N", "100"))
ds = "race#{System.unique_integer([:positive])}"
ws = Barkpark.Tenancy.get_default_workspace()
token = "race-token-#{System.unique_integer([:positive])}"
{:ok, _} = Barkpark.Auth.create_token(token, "race", ds, ["read", "write", "admin"], ws.id)

post_raw = fn mutations ->
  r = Req.post!("http://127.0.0.1:4799/v1/schemas/#{ds}",
        headers: [{"authorization", "Bearer " <> token}],
        json: mutations, retry: false, decode_body: false)
  %{status: r.status, resp_body: r.body}
end

# ConnTest re-raises what Plug.ErrorHandler would render as a 500 in prod.
post = fn mutations ->
  try do
    r = post_raw.(mutations)
    %{status: r.status, body: r.resp_body}
  rescue
    e -> %{status: {:raised, e.__struct__}, body: Exception.message(e) |> String.slice(0, 200)}
  catch
    kind, reason -> %{status: {:caught, kind}, body: inspect(reason) |> String.slice(0, 200)}
  end
end

results =
  for i <- 1..n do
    name = "racetype#{i}"
    mk = fn t -> %{"name" => name, "title" => t, "visibility" => "public", "fields" => [%{"name" => "title", "type" => "string"}]} end
    a = Task.async(fn -> post.(mk.("A")) end)
    b = Task.async(fn -> post.(mk.("B")) end)
    {Task.await(a, 30_000), Task.await(b, 30_000)}
  end

statuses = Enum.flat_map(results, fn {a, b} -> [a.status, b.status] end)
IO.puts("dataset=#{ds} iterations=#{n}")
IO.puts("status counts: " <> inspect(Enum.frequencies(statuses), width: :infinity))

for {a, b} <- results, r <- [a, b], r.status not in [200, 201], uniq: true do
  "#{inspect(r.status)} #{String.slice(r.body, 0, 300)}"
end
|> Enum.take(5)
|> Enum.each(&IO.puts("non-2xx body: " <> &1))

import Ecto.Query
{deleted, _} = Barkpark.Repo.delete_all(from(s in Barkpark.Content.SchemaDefinition, where: s.dataset == ^ds))
IO.puts("cleanup: deleted #{deleted} schemas")
