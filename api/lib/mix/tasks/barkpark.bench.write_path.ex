defmodule Mix.Tasks.Barkpark.Bench.WritePath do
  @shortdoc "Times product-sized document writes through the mutate batch path"

  @moduledoc """
  Writes product-sized documents through `Barkpark.Content.apply_mutations/3`,
  the function `POST /v1/data/mutate` calls, and prints documents per second.

      BARKPARK_DEV_DATABASE=barkpark_bench_write_path \\
        mix barkpark.bench.write_path --docs 1000 --batch 100 --concurrency 1,4 \\
          --modes two_step,direct

  Run it against a throwaway database. `BARKPARK_DEV_DATABASE` points the dev
  Repo at one (see `config/runtime.exs`), and the task creates and migrates it.
  The task refuses to run against `barkpark_dev`, so a developer's own data is
  never written to.

  ## Modes

    * `two_step` sends `createOrReplace` then `publish` for each document. This
      is the path that exists on every version: a draft insert, a published row
      write and a draft delete per document.
    * `direct` sends `{"createOrReplace": doc, "publish": true}`, which writes
      the published row in one row write. A server without the option refuses
      the batch, and the task prints the refusal.
    * `draft` sends `createOrReplace` alone, for comparison.

  ## Documents

  Each document is a `bench_product` with 30 top-level fields: strings, a
  slug, numbers, booleans, dates, a reference to a `bench_brand`, an array of
  category references, a composite of dimensions, and an array of named
  `bench_variant` objects that each hold a nested array of attributes. Every
  run writes fresh ids, so each write is a create.

  ## Options

    * `--docs` documents per run (default 1000)
    * `--batch` documents per mutate batch (default 100)
    * `--concurrency` comma list of concurrent writers (default `1,4`)
    * `--modes` comma list of modes (default `two_step,direct`)
    * `--warmup` documents written once before timing (default 50)
  """
  use Mix.Task

  alias Barkpark.{Content, Tenancy}
  alias Barkpark.Content.CallerContext

  @dataset "production"
  @switches [
    docs: :integer,
    batch: :integer,
    concurrency: :string,
    modes: :string,
    warmup: :integer
  ]

  @impl Mix.Task
  def run(argv) do
    {opts, _rest, _invalid} = OptionParser.parse(argv, strict: @switches)

    if Mix.env() != :dev or System.get_env("BARKPARK_DEV_DATABASE") in [nil, ""] do
      Mix.raise(
        "run with MIX_ENV=dev and BARKPARK_DEV_DATABASE=<throwaway database>; " <>
          "this task writes thousands of documents"
      )
    end

    if System.get_env("BARKPARK_DEV_DATABASE") == "barkpark_dev" do
      Mix.raise("refusing to write benchmark documents into barkpark_dev")
    end

    Mix.Task.run("ecto.create", ["--quiet"])
    Mix.Task.run("ecto.migrate", ["--quiet"])
    Logger.configure(level: :warning)
    Mix.Task.run("app.start")

    docs = Keyword.get(opts, :docs, 1000)
    batch = Keyword.get(opts, :batch, 100)
    warmup = Keyword.get(opts, :warmup, 50)
    concurrency = opts |> Keyword.get(:concurrency, "1,4") |> parse_ints()
    modes = opts |> Keyword.get(:modes, "two_step,direct") |> String.split(",", trim: true)

    scope = setup_workspace!()
    brands = seed_brands!(scope)

    Mix.shell().info(
      "write path bench: #{docs} docs, batch #{batch}, git #{git_sha()}, " <>
        "edge incremental #{Barkpark.EdgeProjector.Settings.get().incremental_project}"
    )

    Mix.shell().info(
      String.pad_trailing("mode", 10) <>
        String.pad_leading("writers", 8) <>
        String.pad_leading("seconds", 10) <>
        String.pad_leading("docs/s", 10) <>
        String.pad_leading("p50 ms", 10) <> String.pad_leading("p95 ms", 10) <> "  errors"
    )

    for mode <- modes do
      _ = run_mode(mode, warmup, batch, 1, scope, brands, "warm")

      for writers <- concurrency do
        report(mode, writers, run_mode(mode, docs, batch, writers, scope, brands, "run"))
      end
    end

    :ok
  end

  defp parse_ints(csv),
    do: csv |> String.split(",", trim: true) |> Enum.map(&String.to_integer(String.trim(&1)))

  defp git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end

  # ── setup ────────────────────────────────────────────────────────────────

  defp setup_workspace! do
    tag = System.unique_integer([:positive]) |> Integer.to_string()

    {:ok, ws} =
      Tenancy.create_workspace(%{slug: "bench-wp-#{tag}", name: "Write path bench #{tag}"})

    caller =
      CallerContext.from_token(%{
        id: Ecto.UUID.generate(),
        permissions: ["read", "write", "admin"]
      })

    opts = [source: :api, workspace_id: ws.id, caller_context: caller, memoize: true]

    for schema <- schemas() do
      {:ok, _} = Content.upsert_schema(schema, @dataset, workspace_id: ws.id)
    end

    opts
  end

  defp schemas do
    [
      %{
        "name" => "bench_brand",
        "title" => "Bench brand",
        "visibility" => "public",
        "fields" => [
          %{"name" => "title", "type" => "string"},
          %{"name" => "country", "type" => "string"}
        ]
      },
      %{
        "name" => "bench_variant",
        "title" => "Bench variant",
        "kind" => "object",
        "fields" => [
          %{"name" => "sku", "type" => "string"},
          %{"name" => "size", "type" => "string"},
          %{"name" => "color", "type" => "string"},
          %{"name" => "price", "type" => "number"},
          %{"name" => "stock", "type" => "integer"},
          %{
            "name" => "attributes",
            "type" => "arrayOf",
            "of" => %{
              "type" => "composite",
              "fields" => [
                %{"name" => "key", "type" => "string"},
                %{"name" => "value", "type" => "string"}
              ]
            }
          }
        ]
      },
      %{
        "name" => "bench_product",
        "title" => "Bench product",
        "visibility" => "public",
        "fields" =>
          [
            %{"name" => "title", "type" => "string"},
            %{"name" => "slug", "type" => "slug"},
            %{"name" => "subtitle", "type" => "string"},
            %{"name" => "summary", "type" => "text"},
            %{"name" => "description", "type" => "text"},
            %{"name" => "price", "type" => "number"},
            %{"name" => "vat", "type" => "number"},
            %{"name" => "stock", "type" => "integer"},
            %{"name" => "active", "type" => "boolean"},
            %{"name" => "featured", "type" => "boolean"},
            %{"name" => "released", "type" => "date"},
            %{"name" => "updated", "type" => "datetime"},
            %{"name" => "brand", "type" => "reference", "refType" => "bench_brand"},
            %{
              "name" => "related",
              "type" => "arrayOf",
              "of" => %{"type" => "reference", "refType" => "bench_brand"}
            },
            %{"name" => "tags", "type" => "tags"},
            %{
              "name" => "dimensions",
              "type" => "composite",
              "fields" => [
                %{"name" => "width", "type" => "number"},
                %{"name" => "height", "type" => "number"},
                %{"name" => "depth", "type" => "number"},
                %{"name" => "weight", "type" => "number"}
              ]
            },
            %{"name" => "variants", "type" => "arrayOf", "of" => %{"type" => "bench_variant"}}
          ] ++
            for(i <- 1..13, do: %{"name" => "spec_#{i}", "type" => "string"})
      }
    ]
  end

  defp seed_brands!(opts) do
    ids = for i <- 1..10, do: "bench-brand-#{System.unique_integer([:positive])}-#{i}"

    mutations =
      Enum.flat_map(ids, fn id ->
        [
          %{
            "createOrReplace" => %{
              "_id" => id,
              "_type" => "bench_brand",
              "title" => "Brand #{id}",
              "country" => "NO"
            }
          },
          %{"publish" => %{"id" => id, "type" => "bench_brand"}}
        ]
      end)

    {:ok, _} = Content.apply_mutations(mutations, @dataset, opts)
    ids
  end

  # ── documents ────────────────────────────────────────────────────────────

  defp product(id, n, brands) do
    brand = Enum.at(brands, rem(n, length(brands)))
    related = Enum.take(Enum.drop(brands, rem(n, 5)), 3)

    %{
      "_id" => id,
      "_type" => "bench_product",
      "title" => "Product #{n} #{id}",
      "slug" => %{"_type" => "slug", "current" => "product-#{id}"},
      "subtitle" => "A product with a subtitle #{n}",
      "summary" => String.duplicate("Summary text for the product card. ", 6),
      "description" => String.duplicate("A longer description paragraph about materials. ", 30),
      "price" => 199.0 + n,
      "vat" => 0.25,
      "stock" => rem(n * 7, 300),
      "active" => true,
      "featured" => rem(n, 9) == 0,
      "released" => "2026-09-01",
      "updated" => "2026-10-01T10:00:00Z",
      "brand" => %{"_type" => "reference", "_ref" => brand},
      "related" =>
        Enum.map(related, fn r -> %{"_type" => "reference", "_ref" => r, "_key" => r} end),
      "tags" => ["bench", "product", "tag-#{rem(n, 20)}"],
      "dimensions" => %{"width" => 30.5, "height" => 12.0, "depth" => 4.2, "weight" => 0.8},
      "variants" =>
        for v <- 1..4 do
          %{
            "_key" => "v#{v}",
            "_type" => "bench_variant",
            "sku" => "SKU-#{n}-#{v}",
            "size" => Enum.at(~w(S M L XL), v - 1),
            "color" => Enum.at(~w(red green blue black), rem(n + v, 4)),
            "price" => 199.0 + n + v,
            "stock" => v * 3,
            "attributes" => Enum.map(1..3, &attribute/1)
          }
        end
    }
    |> Map.merge(Map.new(1..13, fn i -> {"spec_#{i}", "Specification value #{i} for #{n}"} end))
  end

  defp attribute(a), do: %{"_key" => "a#{a}", "key" => "attr#{a}", "value" => "val#{a}"}

  defp mutations("two_step", doc) do
    [
      %{"createOrReplace" => doc},
      %{"publish" => %{"id" => doc["_id"], "type" => doc["_type"]}}
    ]
  end

  defp mutations("direct", doc), do: [%{"createOrReplace" => doc, "publish" => true}]
  defp mutations("draft", doc), do: [%{"createOrReplace" => doc}]

  # ── timing ───────────────────────────────────────────────────────────────

  defp run_mode(mode, docs, batch, writers, scope, brands, label) do
    prefix = "bench-#{label}-#{mode}-#{System.unique_integer([:positive])}"

    batches =
      0..(docs - 1)
      |> Enum.map(fn n -> product("#{prefix}-#{n}", n, brands) end)
      |> Enum.chunk_every(batch)
      |> Enum.map(fn chunk -> Enum.flat_map(chunk, &mutations(mode, &1)) end)

    lanes =
      batches
      |> Enum.with_index()
      |> Enum.group_by(fn {_b, i} -> rem(i, writers) end, fn {b, _i} -> b end)
      |> Map.values()

    :erlang.garbage_collect()
    started = System.monotonic_time(:microsecond)

    timings =
      lanes
      |> Task.async_stream(
        fn lane ->
          Enum.map(lane, fn mutations ->
            t0 = System.monotonic_time(:microsecond)
            result = Content.apply_mutations(mutations, @dataset, scope)
            elapsed = System.monotonic_time(:microsecond) - t0

            # Each HTTP request starts with an empty memo; reset so a batch
            # here cannot reuse what the previous batch read.
            Barkpark.Content.WriteScope.reset_request_memo()

            case result do
              {:ok, _} -> {:ok, elapsed}
              other -> {:error, elapsed, other}
            end
          end)
        end,
        max_concurrency: writers,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, list} -> list end)

    total = System.monotonic_time(:microsecond) - started
    %{docs: docs, total_us: total, timings: timings}
  end

  defp report(mode, writers, %{docs: docs, total_us: total, timings: timings}) do
    errors = Enum.filter(timings, &match?({:error, _, _}, &1))
    ms = timings |> Enum.map(&elem(&1, 1)) |> Enum.map(&(&1 / 1000)) |> Enum.sort()
    seconds = total / 1_000_000

    Mix.shell().info(
      String.pad_trailing(mode, 10) <>
        String.pad_leading(Integer.to_string(writers), 8) <>
        String.pad_leading(:erlang.float_to_binary(seconds, decimals: 1), 10) <>
        String.pad_leading(:erlang.float_to_binary(docs / seconds, decimals: 1), 10) <>
        String.pad_leading(fmt(percentile(ms, 0.5)), 10) <>
        String.pad_leading(fmt(percentile(ms, 0.95)), 10) <>
        "  #{length(errors)}"
    )

    case errors do
      [{:error, _, reason} | _] -> Mix.shell().info("  first error: #{inspect(reason, limit: 8)}")
      [] -> :ok
    end
  end

  defp percentile([], _p), do: 0.0

  defp percentile(sorted, p),
    do: Enum.at(sorted, min(length(sorted) - 1, trunc(p * length(sorted))))

  defp fmt(v), do: :erlang.float_to_binary(v * 1.0, decimals: 0)
end
