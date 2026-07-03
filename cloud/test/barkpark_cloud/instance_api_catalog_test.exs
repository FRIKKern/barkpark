defmodule BarkparkCloud.Registry.InstanceApiCatalogTest do
  @moduledoc """
  The instance-API catalog is the proxy's ALLOWLIST (charter decision D46), so
  these tests are about the allowlist's own integrity — pure, no DB, no HTTP:

    * every entry is well-formed: a valid two-tier grammar, an exact "/"-rooted
      template with no traversal or baked query, a method matching its tier
    * the tier grammar is EXACTLY `:read | :mutate` — there are ZERO `:destroy`
      entries (D46: `webhook.delete` is `:mutate`, deletion is recreatable config
      and does NOT inherit the Hetzner catalog's `:destroy` ceremony)
    * capability ids are unique — exact-match lookup can never be ambiguous
    * v1 is exactly the eight webhook capabilities
    * `fetch/1` is exact-match only — no strings, no near-misses
    * `render_path/2` substitutes only declared placeholders, and refuses a
      missing / path-reshaping value
  """
  use ExUnit.Case, async: true

  alias BarkparkCloud.Registry.InstanceApiCatalog, as: Catalog

  @v1_capabilities ~w(
    webhook.list webhook.show webhook.create webhook.update
    webhook.delete webhook.rotate webhook.deliveries webhook.replay
  )a

  describe "catalog/0 integrity" do
    test "every entry is well-formed data: a capability atom, a two-tier grammar, string params" do
      for entry <- Catalog.catalog() do
        assert is_atom(entry.capability)
        assert entry.tier in [:read, :mutate]
        assert entry.method in [:get, :post, :put, :delete]
        assert is_list(entry.params)
        assert Enum.all?(entry.params, &is_binary/1)
      end
    end

    test ~s(every path is an exact "/"-rooted template with no traversal or query baked in) do
      for entry <- Catalog.catalog() do
        assert String.starts_with?(entry.path, "/"),
               "#{entry.capability} path must start with /: #{entry.path}"

        refute entry.path =~ "..", "#{entry.capability} path must not traverse: #{entry.path}"
        refute entry.path =~ "?", "query params belong in :params, not the path template"
        refute entry.path =~ " ", "no whitespace in a path template"
      end
    end

    test "capability ids are unique — exact-match lookup is never ambiguous" do
      caps = Enum.map(Catalog.catalog(), & &1.capability)
      assert caps == Enum.uniq(caps)
    end

    test "tier semantics match methods: reads GET, mutates POST/PUT/DELETE" do
      for entry <- Catalog.catalog() do
        case entry.tier do
          :read -> assert entry.method == :get
          :mutate -> assert entry.method in [:post, :put, :delete]
        end
      end
    end

    test "every declared placeholder in a path is also declared in :params" do
      for entry <- Catalog.catalog() do
        for key <- Catalog.placeholders(entry.path) do
          assert key in entry.params,
                 "#{entry.capability}: template references {#{key}} not in :params"
        end
      end
    end
  end

  describe "tier grammar (charter decision D46 — no :destroy tier)" do
    test "the catalog has ONLY :read and :mutate — zero :destroy entries exist" do
      tiers = Catalog.catalog() |> Enum.map(& &1.tier) |> Enum.uniq() |> Enum.sort()
      assert tiers == [:mutate, :read]
      refute Enum.any?(Catalog.catalog(), &(&1.tier == :destroy))
    end

    test "webhook.delete is :mutate (recreatable config), a DELETE — never :destroy" do
      assert {:ok, entry} = Catalog.fetch(:"webhook.delete")
      assert entry.tier == :mutate
      assert entry.method == :delete
    end

    test "the five write capabilities are :mutate; the three reads are :read" do
      mutates =
        Catalog.catalog() |> Enum.filter(&(&1.tier == :mutate)) |> Enum.map(& &1.capability)

      reads = Catalog.catalog() |> Enum.filter(&(&1.tier == :read)) |> Enum.map(& &1.capability)

      assert Enum.sort(mutates) ==
               Enum.sort(
                 ~w(webhook.create webhook.update webhook.delete webhook.rotate webhook.replay)a
               )

      assert Enum.sort(reads) == Enum.sort(~w(webhook.list webhook.show webhook.deliveries)a)
    end
  end

  describe "v1 surface" do
    test "exactly the eight webhook capabilities are declared, nothing more" do
      caps = Catalog.catalog() |> Enum.map(& &1.capability) |> Enum.sort()
      assert caps == Enum.sort(@v1_capabilities)
    end

    test "the templates match the frozen contract" do
      expected = %{
        "webhook.list" => {:get, "/v1/webhooks/{dataset}"},
        "webhook.show" => {:get, "/v1/webhooks/{dataset}/{id}"},
        "webhook.create" => {:post, "/v1/webhooks/{dataset}"},
        "webhook.update" => {:put, "/v1/webhooks/{dataset}/{id}"},
        "webhook.delete" => {:delete, "/v1/webhooks/{dataset}/{id}"},
        "webhook.rotate" => {:post, "/v1/webhooks/{dataset}/{id}/rotate"},
        "webhook.deliveries" => {:get, "/v1/webhooks/{dataset}/{id}/deliveries"},
        "webhook.replay" => {:post, "/v1/webhooks/{dataset}/{id}/deliveries/{event_id}/replay"}
      }

      for {cap, {method, path}} <- expected do
        assert {:ok, entry} = Catalog.fetch(String.to_atom(cap))
        assert entry.method == method
        assert entry.path == path
      end
    end
  end

  describe "fetch/1 — exact match only" do
    test "hits on an exact capability atom" do
      assert {:ok, %{path: "/v1/webhooks/{dataset}", tier: :read}} =
               Catalog.fetch(:"webhook.list")

      assert {:ok, %{tier: :mutate}} = Catalog.fetch(:"webhook.rotate")
    end

    test "misses on anything else — unknown caps, strings, near-misses" do
      assert :error = Catalog.fetch(:"webhook.purge")
      assert :error = Catalog.fetch(:"dataset.list")
      # Strings never coerce — no user-controlled atom into the allowlist.
      assert :error = Catalog.fetch("webhook.list")
      assert :error = Catalog.fetch(:webhook)
    end
  end

  describe "render_path/2" do
    test "substitutes declared placeholders from string values" do
      {:ok, list} = Catalog.fetch(:"webhook.list")

      assert Catalog.render_path(list, %{"dataset" => "production"}) ==
               {:ok, "/v1/webhooks/production"}

      {:ok, show} = Catalog.fetch(:"webhook.show")

      assert Catalog.render_path(show, %{"dataset" => "staging", "id" => "wh_42"}) ==
               {:ok, "/v1/webhooks/staging/wh_42"}

      {:ok, replay} = Catalog.fetch(:"webhook.replay")

      assert Catalog.render_path(replay, %{
               "dataset" => "production",
               "id" => "wh_42",
               "event_id" => "evt_9"
             }) == {:ok, "/v1/webhooks/production/wh_42/deliveries/evt_9/replay"}
    end

    test "a missing or empty placeholder value is an error — never a malformed path" do
      {:ok, show} = Catalog.fetch(:"webhook.show")

      assert {:error, {:missing_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "production"})

      assert {:error, {:missing_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "p", "id" => ""})

      assert {:error, {:missing_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "p", "id" => nil})
    end

    test "a value carrying a URL-reshaping character is refused — path, query, AND fragment" do
      {:ok, show} = Catalog.fetch(:"webhook.show")

      # `/` — path traversal.
      assert {:error, {:bad_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "production", "id" => "wh/../secrets"})

      # `?` — query-string injection into the upstream call.
      assert {:error, {:bad_param, "dataset"}} =
               Catalog.render_path(show, %{"dataset" => "prod?admin=1", "id" => "wh_1"})

      # `#` — fragment truncation.
      assert {:error, {:bad_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "production", "id" => "wh_1#frag"})

      # `%` — smuggled double-encoding.
      assert {:error, {:bad_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "production", "id" => "wh%2F1"})

      # Whitespace — malformed URL.
      assert {:error, {:bad_param, "id"}} =
               Catalog.render_path(show, %{"dataset" => "production", "id" => "wh 1"})
    end

    test "the RFC 3986 unreserved set passes — slugs, UUIDs, prefixed ids" do
      {:ok, show} = Catalog.fetch(:"webhook.show")

      assert {:ok, _} =
               Catalog.render_path(show, %{
                 "dataset" => "my-data.set_2",
                 "id" => "0b19e1cc-7f6e-4d21-9c2a-1f0e8a7b6c5d"
               })
    end
  end
end
