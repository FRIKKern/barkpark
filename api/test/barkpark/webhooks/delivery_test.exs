defmodule Barkpark.Webhooks.DeliveryTest do
  use ExUnit.Case, async: true

  alias Barkpark.Webhooks.Delivery

  @valid_attrs %{
    endpoint_id: "11111111-1111-1111-1111-111111111111",
    event_id: 42
  }

  describe "changeset/2 — valid attrs" do
    test "accepts required fields and is valid" do
      cs = Delivery.changeset(%Delivery{}, @valid_attrs)
      assert cs.valid?
    end

    test "populates defaults from the struct" do
      cs = Delivery.changeset(%Delivery{}, @valid_attrs)
      assert Ecto.Changeset.get_field(cs, :status) == "pending"
      assert Ecto.Changeset.get_field(cs, :attempts) == 0
    end

    test "accepts all optional fields" do
      attrs =
        Map.merge(@valid_attrs, %{
          status: "ok",
          attempts: 3,
          last_status_code: 200,
          last_error_text: nil
        })

      cs = Delivery.changeset(%Delivery{}, attrs)
      assert cs.valid?
      assert Ecto.Changeset.get_field(cs, :status) == "ok"
      assert Ecto.Changeset.get_field(cs, :attempts) == 3
      assert Ecto.Changeset.get_field(cs, :last_status_code) == 200
    end
  end

  describe "changeset/2 — required fields" do
    test "is invalid when endpoint_id is missing" do
      cs = Delivery.changeset(%Delivery{}, %{event_id: 1})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :endpoint_id)
    end

    test "is invalid when event_id is missing" do
      cs = Delivery.changeset(%Delivery{}, %{endpoint_id: "11111111-1111-1111-1111-111111111111"})
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :event_id)
    end
  end

  describe "changeset/2 — status validation" do
    test "rejects an unknown status value" do
      cs = Delivery.changeset(%Delivery{}, Map.put(@valid_attrs, :status, "unknown_status"))
      refute cs.valid?
      assert Keyword.has_key?(cs.errors, :status)
    end

    test "accepts all declared statuses" do
      for status <- ~w(pending ok failed_giveup) do
        cs = Delivery.changeset(%Delivery{}, Map.put(@valid_attrs, :status, status))
        assert cs.valid?, "expected valid? for status=#{status}"
      end
    end
  end
end
