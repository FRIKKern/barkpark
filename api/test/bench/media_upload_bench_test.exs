defmodule Barkpark.Bench.MediaUploadBenchTest do
  @moduledoc """
  Opt-in benchmark for task-50cabce448b02af7: upload N images, then request
  three sizes of each, through the real endpoint and media plugin. Skipped
  unless `MEDIA_BENCH_IMAGES` names a directory of JPEG or PNG files.

      MEDIA_BENCH_IMAGES=/abs/dir mix test test/bench/media_upload_bench_test.exs

  Uploads run one after another, the way `bp media upload` sends them. On a
  build with on-demand transforms the three sizes are `?w=320`, `?w=800` and
  `?w=1600` on the original's URL. On a build without them (to measure the
  baseline) they are the `thumb`, `preview` and `hero` presets. Each size is
  requested twice: the first request may render, the second reads the cache.
  It also counts `mediaAsset` document writes per upload from `revisions`.
  """
  use BarkparkWeb.ConnCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Content.Revision
  alias Barkpark.Media
  alias Barkpark.Plugins.Media.Assets
  alias Barkpark.Repo

  @dir System.get_env("MEDIA_BENCH_IMAGES")

  @moduletag timeout: :infinity
  @moduletag ownership_timeout: 3_600_000

  if is_nil(@dir) do
    @moduletag :skip
  end

  setup do
    Auth.create_token("barkpark-dev-token", "dev", "media-bench", ["read", "write", "admin"])

    # Measure the media path, not the per-token request budget.
    original = Application.get_env(:barkpark, :rate_limits, [])

    Application.put_env(
      :barkpark,
      :rate_limits,
      Keyword.merge(original, read_per_minute: 1_000_000, write_per_minute: 1_000_000)
    )

    on_exit(fn -> Application.put_env(:barkpark, :rate_limits, original) end)
    :ok
  end

  test "upload N images, then request three sizes of each", %{conn: conn} do
    files =
      @dir
      |> File.ls!()
      |> Enum.filter(&String.match?(&1, ~r/\.(jpe?g|png)\z/i))
      |> Enum.sort()
      |> Enum.map(&Path.join(@dir, &1))

    transforms? = Code.ensure_loaded?(Barkpark.Media.Transform)

    {upload_us, results} =
      :timer.tc(fn ->
        Enum.map(files, fn path ->
          # Plug deletes nothing here, but copy anyway so the source set is reused.
          tmp =
            Path.join(
              System.tmp_dir!(),
              "bench-#{System.unique_integer([:positive])}" <> Path.extname(path)
            )

          File.cp!(path, tmp)

          upload = %Plug.Upload{
            path: tmp,
            filename: Path.basename(path),
            content_type: "image/jpeg"
          }

          {us, resp} =
            :timer.tc(fn ->
              conn
              |> recycle()
              |> put_req_header("authorization", "Bearer barkpark-dev-token")
              |> post(~p"/v1/media/production/upload", %{"file" => upload})
            end)

          body = json_response(resp, 201)
          {us, body["result"]}
        end)
      end)

    upload_times = Enum.map(results, &elem(&1, 0))
    assets = Enum.map(results, &elem(&1, 1))

    writes =
      Enum.map(assets, fn %{"id" => id} ->
        Repo.aggregate(
          from(r in Revision, where: r.doc_id in [^"asset-#{id}", ^"drafts.asset-#{id}"]),
          :count
        )
      end)

    urls = fn asset ->
      if transforms? do
        Enum.map(~w(320 800 1600), &(asset["originalUrl"] <> "?w=" <> &1))
      else
        Enum.map(~w(thumb preview hero), &asset["renditions"][&1])
      end
    end

    fetch_all = fn ->
      Enum.flat_map(assets, fn asset ->
        Enum.map(urls.(asset), fn url ->
          {us, resp} = :timer.tc(fn -> get(build_conn(), url) end)
          assert resp.status == 200, "GET #{url} answered #{resp.status}"
          us
        end)
      end)
    end

    {first_us, first_times} = :timer.tc(fetch_all)
    {second_us, second_times} = :timer.tc(fetch_all)

    IO.puts("""

    media bench (#{if transforms?, do: "on-demand transforms", else: "baseline presets"})
      images:                 #{length(files)}
      upload total:           #{ms(upload_us)} ms (#{rate(length(files), upload_us)} images/min)
      upload per image:       median #{ms(median(upload_times))} ms, p95 #{ms(p95(upload_times))} ms
      asset writes / upload:  #{Enum.min(writes)}..#{Enum.max(writes)} (mean #{Float.round(Enum.sum(writes) / length(writes), 2)})
      3 sizes, first request: #{ms(first_us)} ms total, median #{ms(median(first_times))} ms, p95 #{ms(p95(first_times))} ms
      3 sizes, cached:        #{ms(second_us)} ms total, median #{ms(median(second_times))} ms, p95 #{ms(p95(second_times))} ms
      upload + first sizes:   #{ms(upload_us + first_us)} ms
    """)

    for %{"id" => id, "path" => path} <- assets do
      File.rm(Path.join(Media.upload_dir(), path))
      Media.Renditions.delete_for_file(id)
      Assets.delete_for_blob(id, "production")
    end
  end

  defp ms(us), do: Float.round(us / 1000, 1)
  defp rate(n, us), do: Float.round(n / (us / 60_000_000), 1)
  defp median(xs), do: xs |> Enum.sort() |> Enum.at(div(length(xs), 2))
  defp p95(xs), do: xs |> Enum.sort() |> Enum.at(min(length(xs) - 1, round(length(xs) * 0.95)))
end
