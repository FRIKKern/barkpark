defmodule Barkpark.Search.HighlighterTest do
  use ExUnit.Case, async: true

  alias Barkpark.Search.Highlighter

  # Minimal struct stand-ins — Highlighter only reads named fields.
  defmodule FakeDoc do
    defstruct [:doc_id, :title, :content]
  end

  defmodule FakeFile do
    defstruct [:id, :original_name, :filename]
  end

  describe "highlight_documents/3" do
    test "wraps matching term in <mark> tags" do
      doc = %FakeDoc{doc_id: "d1", title: "Elixir is great", content: %{}}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      assert result["d1"]["title"] == "<mark>elixir</mark> is great"
    end

    test "returns no entry for title when no needle matches" do
      doc = %FakeDoc{doc_id: "d1", title: "Something else", content: %{}}
      parsed = %{terms: ["phoenix"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      assert result["d1"] == %{}
    end

    test "matching is case-insensitive, replaces preserving needle case" do
      doc = %FakeDoc{doc_id: "d2", title: "ELIXIR and Elixir", content: %{}}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})
      highlighted = result["d2"]["title"]

      assert highlighted =~ "<mark>elixir</mark>"
    end

    test "handles nil title without crashing (field omitted from result)" do
      doc = %FakeDoc{doc_id: "d3", title: nil, content: %{}}
      parsed = %{terms: ["test"], phrases: [], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      refute Map.has_key?(result["d3"], "title")
    end

    test "highlights phrase needles as well as terms" do
      doc = %FakeDoc{doc_id: "d4", title: "exact phrase here", content: %{}}
      parsed = %{terms: [], phrases: ["exact phrase"], prefixes: []}

      result = Highlighter.highlight_documents([doc], parsed, %{})

      assert result["d4"]["title"] == "<mark>exact phrase</mark> here"
    end
  end

  describe "highlight_media/4" do
    test "highlights filename when it contains the needle" do
      file = %FakeFile{id: 42, original_name: "photo.jpg", filename: "elixir-logo.png"}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}

      result = Highlighter.highlight_media([file], parsed, %{}, %{})

      assert result["42"]["filename"] == "<mark>elixir</mark>-logo.png"
    end

    test "uses doc title when file is matched with title field config" do
      file = %FakeFile{id: 7, original_name: "img.png", filename: "img.png"}
      fake_doc = %FakeDoc{doc_id: "d1", title: "Elixir Book", content: %{}}
      parsed = %{terms: ["elixir"], phrases: [], prefixes: []}
      config = %{"highlight_fields" => ["title"]}

      result = Highlighter.highlight_media([file], parsed, config, %{7 => fake_doc})

      assert result["7"]["title"] == "<mark>elixir</mark> Book"
    end
  end
end
