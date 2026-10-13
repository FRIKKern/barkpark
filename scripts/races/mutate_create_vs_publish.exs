# Prod-shape race: createOrReplace X vs publish X, two REAL concurrent HTTP
# requests against a real listener, no Ecto sandbox (task-0ff551450cafe6a3,
# task-f25c61a3a3c2cb9d). Not an ExUnit test: the sandbox serializes it.
#
#   cd api && MIX_TEST_PARTITION=race MIX_ENV=test mix test test/barkpark/release_media_sha1_backfill_test.exs  # creates the DB
#   cd api && RACE_N=100 MIX_TEST_PARTITION=race MIX_ENV=test mix run --no-start ../scripts/races/mutate_create_vs_publish.exs
#
# Prints the status counts per side and up to 5 non-2xx bodies; deletes its
# own dataset's documents at the end. Listens on 127.0.0.1:4799.
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
  r = Req.post!("http://127.0.0.1:4799/v1/data/mutate/#{ds}",
        headers: [{"authorization", "Bearer " <> token}],
        json: %{"mutations" => mutations}, retry: false, decode_body: false)
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
    id = "race-#{i}"
    seed = post.([%{"createOrReplace" => %{"_id" => id, "_type" => "post", "title" => "v0"}}])
    if seed.status != 200, do: IO.puts("seed #{i}: #{inspect(seed.status)}")

    a = Task.async(fn -> post.([%{"createOrReplace" => %{"_id" => id, "_type" => "post", "title" => "v#{i}"}}]) end)
    b = Task.async(fn -> post.([%{"publish" => %{"id" => id, "type" => "post"}}]) end)
    {Task.await(a, 30_000), Task.await(b, 30_000)}
  end

statuses = Enum.flat_map(results, fn {a, b} -> [{:create, a.status}, {:publish, b.status}] end)
IO.puts("dataset=#{ds} iterations=#{n}")
IO.puts("status counts: " <> inspect(Enum.frequencies(statuses), width: :infinity))

for {a, b} <- results, r <- [a, b], r.status != 200, uniq: true do
  "#{inspect(r.status)} #{String.slice(r.body, 0, 300)}"
end
|> Enum.take(5)
|> Enum.each(&IO.puts("non-2xx body: " <> &1))

# cleanup: the throwaway dataset's documents and token
import Ecto.Query
{deleted, _} = Barkpark.Repo.delete_all(from(d in Barkpark.Content.Document, where: d.dataset == ^ds))
IO.puts("cleanup: deleted #{deleted} documents")
