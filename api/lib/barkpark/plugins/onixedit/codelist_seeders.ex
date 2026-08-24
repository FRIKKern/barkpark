defmodule Barkpark.Plugins.OnixEdit.CodelistSeeders do
  @moduledoc """
  OnixEdit's codelist contract — the seed functions the host invokes and
  the declarative list of codelist requirements the schema references.

  Two faces of the same concern grouped here:

    * `seeders/0` — the function captures the host runs to populate the
      EDItEUR + Thema registries.
    * `requirements/0` — the declarative `{plugin_name, list_id, issue}`
      contract WI3's importer reads to know which lists must be importable.

  Extracted verbatim from `Barkpark.Plugins.OnixEdit.codelist_seeders/0`
  and `codelist_requirements/0` behind the plugin facade — the callers
  delegate here. The returned values are byte-identical to before.
  """

  alias Barkpark.Codelists.EDItEUR

  @plugin_name "onixedit"

  @doc """
  The codelist seed function captures. Returned unchanged from the former
  `OnixEdit.codelist_seeders/0` body.
  """
  @spec seeders() :: [(-> any())]
  def seeders do
    [
      &Barkpark.Codelists.EDItEUR.seed_bundled/0,
      &Barkpark.Codelists.EDItEUR.seed_thema/0
    ]
  end

  @doc """
  Codelist requirements declared by the OnixEdit plugin.

  Each entry names a codelist that the plugin's schema references. Seeding is
  **WI3's job** — these declarations are the contract WI3 reads. Per D21 we
  do NOT bundle EDItEUR XML; the publisher brings their licensed snapshot
  and `mix barkpark.codelists.import` (WI3) populates the registry.

  The shape is intentionally simple: a list of maps with `:plugin_name`,
  `:list_id`, and `:issue`. WI3 may extend this to richer metadata once the
  importer exists; until then, this is the soft hand-off point.

  Returned unchanged from the former `OnixEdit.codelist_requirements/0` body.
  """
  @spec requirements() :: [
          %{plugin_name: String.t(), list_id: String.t(), issue: String.t()}
        ]
  def requirements do
    [
      # Critical lists pinned in the masterplan (D17 / D21).
      %{plugin_name: @plugin_name, list_id: "onixedit:contributor_role", issue: "17"},
      # Thema's issue is "1.6", not "93". EDItEUR publishes Thema SEPARATELY
      # from the ONIX codelist bundle, and the numeric ONIX list 93 is
      # "Supplier role" — a fact `Barkpark.Codelists.EDItEUR` already
      # documents at length. The 93 that sits next to Thema in book.json is
      # the `SubjectSchemeIdentifier` VALUE inside ONIX list 27, not a
      # pointer to an ONIX codelist. Read from the seeder's own pinned
      # constant so the declaration cannot drift from what boot writes.
      %{plugin_name: @plugin_name, list_id: "onixedit:thema", issue: EDItEUR.thema_issue()},

      # Lists referenced by the book schema. All pinned to ONIX issue 73.
      %{plugin_name: @plugin_name, list_id: "onixedit:notification_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:record_source_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:name_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:barcode_indicator", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_form", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_form_detail", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_form_feature_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_packaging", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_technical_protection", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_usage_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_usage_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:epub_usage_unit", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:extent_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:extent_unit", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:ancillary_content_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_classification_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:title_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:title_element_level", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:thesis_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:conference_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:website_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:edition_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:bible_contents", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:bible_version", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:study_bible_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:bible_text_feature", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:language_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:language_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:country_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:region_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:script_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:subject_scheme", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_code_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_code_value", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_range_qualifier", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:audience_range_precision", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:complexity_scheme", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:text_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:content_audience", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:cited_content_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:cited_source_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:content_date_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:resource_content_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:resource_mode", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:resource_form", issue: "73"},
      %{
        plugin_name: @plugin_name,
        list_id: "onixedit:resource_version_feature_type",
        issue: "73"
      },
      %{plugin_name: @plugin_name, list_id: "onixedit:prize_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:text_item_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:publishing_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:publishing_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:publishing_date_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:date_format", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:sales_rights_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:sales_restriction_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:work_relation", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:work_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_relation", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:sales_outlet_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:agent_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:market_publishing_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:supplier_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:supplier_id_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:supply_date_role", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:product_availability", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_qualifier", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_status", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:currency_code", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:tax_rate_type", issue: "73"},
      %{plugin_name: @plugin_name, list_id: "onixedit:price_date_role", issue: "73"}
    ]
  end
end
