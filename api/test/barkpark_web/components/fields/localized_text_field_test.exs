defmodule BarkparkWeb.Components.Fields.LocalizedTextFieldTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias BarkparkWeb.Components.Fields.LocalizedTextField
  alias Barkpark.Content.SchemaDefinition.Field

  defp localized_field(opts \\ []) do
    %Field{
      name: "title",
      type: "localizedText",
      title: "Title",
      languages: Keyword.get(opts, :languages, ["nob", "eng", "deu"]),
      format: Keyword.get(opts, :format, :plain),
      fallback_chain: Keyword.get(opts, :fallback_chain, ["nob", "eng", "first-non-empty"])
    }
  end

  describe "fallback chain rendering" do
    test "primary present → no warning rendered" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(),
          value: %{"nob" => "Hei", "eng" => "Hello"}
        })

      refute html =~ "primary translation"
      refute html =~ "bp-localized-warning"
    end

    test "primary missing, secondary used → warning rendered" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(),
          value: %{"eng" => "Hello"}
        })

      assert html =~ ~s(class="warning bp-localized-warning")
      assert html =~ ~s(data-severity="warning")
      assert html =~ ~s(data-missing-primary="nob")
      assert html =~ ~s(data-using-fallback="eng")
      assert html =~ "primary translation"
    end

    test "primary missing, listed missing, first-non-empty saves the day → warning rendered" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(),
          value: %{"deu" => "Hallo"}
        })

      assert html =~ ~s(class="warning bp-localized-warning")
      assert html =~ ~s(data-using-fallback="deu")
    end

    test "all empty → renders error span and no warning" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(),
          value: %{"nob" => "", "eng" => "", "deu" => ""}
        })

      refute html =~ "bp-localized-warning"
      assert html =~ ~s(class="error bp-localized-empty")
      assert html =~ "no translation available"
    end
  end

  describe "empty fallback_chain (schema-parse default)" do
    test "content present, no configured chain → renders content, no error banner" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(fallback_chain: []),
          value: %{"eng" => "Hello"}
        })

      refute html =~ "no translation available"
      refute html =~ "bp-localized-empty"
      refute html =~ "bp-localized-warning"
      assert html =~ "Hello"
    end

    test "truly empty map, no configured chain → still shows empty state" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(fallback_chain: []),
          value: %{"nob" => "", "eng" => "", "deu" => ""}
        })

      assert html =~ ~s(class="error bp-localized-empty")
      assert html =~ "no translation available"
    end

    test "configured chain still resolves per chain (regression guard)" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(fallback_chain: ["nob", "eng", "first-non-empty"]),
          value: %{"eng" => "Hello"}
        })

      assert html =~ ~s(data-missing-primary="nob")
      assert html =~ ~s(data-using-fallback="eng")
      refute html =~ "no translation available"
    end
  end

  describe "render — per-language inputs" do
    test "renders one textarea per declared language" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(languages: ["nob", "eng"]),
          value: %{"nob" => "Hei", "eng" => "Hello"}
        })

      assert html =~ ~s(data-lang="nob")
      assert html =~ ~s(data-lang="eng")
      assert html =~ "Hei"
      assert html =~ "Hello"
      assert html =~ "<textarea"
    end

    test "format :rich marks the textarea with bp-localized-rich class" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(format: :rich),
          value: %{"nob" => "Hei"}
        })

      assert html =~ "bp-localized-rich"
      assert html =~ ~s(data-format="rich")
    end

    test "per-language errors render inline" do
      html =
        render_component(&LocalizedTextField.localized_text_field/1, %{
          field: localized_field(languages: ["nob", "eng"]),
          value: %{"nob" => "Hei"},
          errors: %{"eng" => ["translation required"]}
        })

      assert html =~ "translation required"
      assert html =~ ~s(data-error-for="eng")
    end
  end
end
