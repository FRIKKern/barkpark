defmodule Barkpark.Validation.Checkers.CodelistRefTest do
  use Barkpark.DataCase, async: true

  alias Barkpark.Content.Codelists
  alias Barkpark.Validation.Checkers.CodelistRef

  # Canonical example anchor: ONIX ContributorRole — list 17 issue 73 — used
  # by Phase 4 OnixEdit. Keeping the exact identifiers makes Phase 4 work
  # depend on a green path here.
  @plugin "editeur"
  @list_id "17"
  @issue_73 "73"
  @issue_71 "71"

  defp register_contributor_role!(issue) do
    {:ok, _} =
      Codelists.register(@plugin, @list_id, %{
        issue: issue,
        name: "ONIX Contributor Role #{issue}",
        values: [
          %{code: "A01", translations: [%{language: "eng", label: "By (author)"}]},
          %{code: "B01", translations: [%{language: "eng", label: "Edited by"}]},
          %{code: "E07", translations: [%{language: "eng", label: "Read by"}]}
        ]
      })
  end

  describe "value-in-list" do
    setup do
      register_contributor_role!(@issue_73)
      :ok
    end

    test ":ok when value is present at the requested issue" do
      assert :ok =
               CodelistRef.check("A01", %{
                 registry_id: @plugin,
                 list_id: @list_id,
                 issue: 73
               })
    end

    test "accepts issue as either string or integer" do
      assert :ok =
               CodelistRef.check("B01", %{
                 registry_id: @plugin,
                 list_id: @list_id,
                 issue: "73"
               })
    end

    test "nil and empty-string values bypass the check" do
      params = %{registry_id: @plugin, list_id: @list_id, issue: 73}
      assert :ok = CodelistRef.check(nil, params)
      assert :ok = CodelistRef.check("", params)
    end
  end

  describe "value-not-in-list" do
    setup do
      register_contributor_role!(@issue_73)
      :ok
    end

    test "{:error, :codelist_unknown_value} when value is not in the codelist" do
      assert {:error, :codelist_unknown_value} =
               CodelistRef.check("ZZZ", %{
                 registry_id: @plugin,
                 list_id: @list_id,
                 issue: 73
               })
    end

    test "{:error, :codelist_unknown_value} when (registry_id, list_id) is unknown" do
      assert {:error, :codelist_unknown_value} =
               CodelistRef.check("A01", %{
                 registry_id: "nonexistent_registry",
                 list_id: @list_id,
                 issue: 73
               })
    end
  end

  describe "version mismatch" do
    test "{:error, :codelist_version_mismatch} when only an older issue is loaded" do
      register_contributor_role!(@issue_71)

      assert {:error, :codelist_version_mismatch} =
               CodelistRef.check("A01", %{
                 registry_id: @plugin,
                 list_id: @list_id,
                 issue: 73
               })
    end

    test "version mismatch persists even when the value would be valid in the loaded issue" do
      # Register issue 71 only with B01.
      {:ok, _} =
        Codelists.register(@plugin, @list_id, %{
          issue: @issue_71,
          values: [%{code: "B01"}]
        })

      assert {:error, :codelist_version_mismatch} =
               CodelistRef.check("B01", %{
                 registry_id: @plugin,
                 list_id: @list_id,
                 issue: 73
               })
    end
  end

  describe "plugin-supplied codelist ref" do
    # A plugin (here simulated as a separate plugin_name discriminator) ships
    # its own codelist; the checker resolves it through the same path.
    test ":ok against a plugin-registered codelist" do
      {:ok, _} =
        Codelists.register("acme_publisher", "acme:custom_role", %{
          issue: "1",
          values: [%{code: "EDITOR_IN_CHIEF"}]
        })

      assert :ok =
               CodelistRef.check("EDITOR_IN_CHIEF", %{
                 registry_id: "acme_publisher",
                 list_id: "acme:custom_role",
                 issue: 1
               })

      assert {:error, :codelist_unknown_value} =
               CodelistRef.check("INTERN", %{
                 registry_id: "acme_publisher",
                 list_id: "acme:custom_role",
                 issue: 1
               })
    end
  end
end
