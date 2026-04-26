defmodule Barkpark.Content.ErrorCodesTest do
  use ExUnit.Case, async: true

  alias Barkpark.Content.ErrorCodes

  @expected_codes [
    :required,
    :nilable_violation,
    :one_of,
    :in_violation,
    :nonempty_violation,
    :max_items,
    :checker_failed,
    :type_mismatch,
    :codelist_unknown,
    :codelist_version_mismatch,
    :unknown_field
  ]

  test "registers every code spec'd by Phase 3 WI1/WI2" do
    Enum.each(@expected_codes, fn code ->
      assert {:ok, %{message_template: tmpl, default_severity: sev, since_version: ver}} =
               ErrorCodes.lookup(code)

      assert is_binary(tmpl) and tmpl != ""
      assert sev in [:error, :warning, :info]
      assert is_binary(ver)
    end)
  end

  test "all/0 returns the full set of registered codes" do
    all = ErrorCodes.all()
    Enum.each(@expected_codes, fn code -> assert code in all end)
  end

  test "lookup/1 returns :error for unknown codes" do
    assert ErrorCodes.lookup(:does_not_exist) == :error
    assert ErrorCodes.lookup("string-code") == :error
    assert ErrorCodes.lookup(nil) == :error
  end

  test "render/2 interpolates bindings into the message_template" do
    assert ErrorCodes.render(:max_items, %{max: 3}) =~ "max 3"
    assert ErrorCodes.render(:checker_failed, %{name: "isUrl"}) =~ "isUrl"
    assert ErrorCodes.render(:type_mismatch, %{expected: "string"}) =~ "string"
  end

  test "render/2 falls back to the code name for unknown codes" do
    assert ErrorCodes.render(:not_a_real_code) == "not_a_real_code"
  end

  test "render/2 returns the literal template when no bindings are supplied" do
    assert ErrorCodes.render(:required) == "Required"
  end
end
