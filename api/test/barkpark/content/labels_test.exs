defmodule Barkpark.Content.LabelsTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Labels
  alias Barkpark.Content.Codelists

  # ---------------------------------------------------------------------------
  # codelist_label/3 — nil / blank guards (pure, no DB)
  # ---------------------------------------------------------------------------

  describe "codelist_label/3 — nil and blank guards" do
    test "nil code returns empty string" do
      assert Labels.codelist_label("onixedit", "onixedit:role", nil) == ""
    end

    test "empty string code returns empty string" do
      assert Labels.codelist_label("onixedit", "onixedit:role", "") == ""
    end

    test "blank codelist_id with a real code falls back to the code" do
      assert Labels.codelist_label("onixedit", "", "A01") == "A01"
    end
  end

  # ---------------------------------------------------------------------------
  # codelist_label/3 — DB-backed happy path and fallbacks
  # ---------------------------------------------------------------------------

  describe "codelist_label/3 — registered codelist" do
    setup do
      {:ok, _} =
        Codelists.register("onixedit", "onixedit:contrib", %{
          issue: "1",
          values: [
            %{code: "A01", translations: [%{language: "eng", label: "By (author)"}]},
            %{code: "A02", translations: [%{language: "eng", label: "With"}]}
          ]
        })

      :ok
    end

    test "known code resolves to its label" do
      assert Labels.codelist_label("onixedit", "onixedit:contrib", "A01") == "By (author)"
    end

    test "unknown code falls back to the raw code" do
      assert Labels.codelist_label("onixedit", "onixedit:contrib", "ZZ99") == "ZZ99"
    end

    test "unregistered plugin falls back to the raw code" do
      assert Labels.codelist_label("no-such-plugin", "onixedit:contrib", "A01") == "A01"
    end
  end

  # ---------------------------------------------------------------------------
  # paper_style/2 — pure, no DB
  # ---------------------------------------------------------------------------

  describe "paper_style/2" do
    test "explicit 'article' in attrs wins" do
      assert Labels.paper_style(%{"style" => "article"}, nil) == "article"
    end

    test "explicit 'article-wide' in attrs preserves the editorial width" do
      assert Labels.paper_style(%{"style" => "article-wide"}, nil) == "article-wide"
    end

    test "any other explicit style in attrs normalises to nil" do
      assert Labels.paper_style(%{"style" => "email"}, nil) == nil
    end

    test "falls back to existing doc's stored style when attrs carry no style" do
      existing = %{content: %{"style" => "article"}}
      assert Labels.paper_style(%{}, existing) == "article"
    end

    test "falls back to an existing wide article style" do
      existing = %{content: %{"style" => "article-wide"}}
      assert Labels.paper_style(%{}, existing) == "article-wide"
    end

    test "explicit attrs override existing doc's style" do
      existing = %{content: %{"style" => "article"}}
      assert Labels.paper_style(%{"style" => "email"}, existing) == nil
    end

    test "nil attrs and nil existing returns nil" do
      assert Labels.paper_style(%{}, nil) == nil
    end
  end

  # ---------------------------------------------------------------------------
  # render_opts/1 and paper_render_opts/2 — pure, no DB
  # ---------------------------------------------------------------------------

  describe "render_opts/1" do
    test "returns a map with ref_resolver and codelist_resolver functions" do
      opts = Labels.render_opts("production")
      assert is_function(opts.ref_resolver, 2)
      assert is_function(opts.codelist_resolver, 3)
    end
  end

  describe "paper_render_opts/2" do
    test "'article' style adds :style => :article key" do
      opts = Labels.paper_render_opts("production", "article")
      assert opts.style == :article
      assert is_function(opts.ref_resolver, 2)
    end

    test "non-article style produces same map as render_opts without :style key" do
      opts = Labels.paper_render_opts("production", "email")
      refute Map.has_key?(opts, :style)
    end

    test "nil style produces same map as render_opts without :style key" do
      opts = Labels.paper_render_opts("production", nil)
      refute Map.has_key?(opts, :style)
    end
  end
end
