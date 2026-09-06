defmodule Barkpark.Tenancy.WorkspaceBundleConnectorCredentialExclusionTest do
  @moduledoc """
  EXPORT-SAFETY GATE: connector credentials must never enter a workspace bundle
  (task-fff1116564723b60).

  ## The security reason

  `connector_installs` is the connector bridge's install table. Two of its
  columns — `credential_ref` and `chat_token_ref` — are SEALED AES-256-GCM
  blobs that no Elixir ever decrypts (Connectors D38,
  `Barkpark.Connectors.Install`). They are the connector's credentials.

  Until this gate existed, they stayed out of every bundle by ACCIDENT: the
  table lives in the bridge-owned `chat_bridge` schema (Connectors D28 — no Ecto
  migration may create it), and every `WorkspaceBundle.Catalog` live_* query
  filters `table_schema = 'public'`, so the exporter simply never looked there.
  Nothing pinned that. A migration folding `chat_bridge` into `public`, or a
  workspace-scoped MIRROR of connector config (a table, or a view over the
  bridge's rows), would make the sealed references bundle-reachable with no
  sentinel firing — and the first signal would be a customer's export artifact
  carrying live connector credentials.

  ## What this suite proves

    * the deny is EXPLICIT, by name and by column shape, inside
      `Catalog.assert_connector_credential_exclusion!/1`;
    * the tripwire goes RED on the mutation it exists for — a
      `public.connector_installs` table, and a differently-NAMED public mirror
      exposing the same sealed columns — and it fires from BOTH partition
      sentinels, i.e. before any bundle can be accepted;
    * POSITIVE CONTROL: an ordinary public workspace table (`documents`) is
      still cataloged and still travels, so the guard cannot pass by disabling
      the catalog.

  Every mutation is created and dropped inside the sandboxed connection — the
  test DB is shared, and no migration ships here by design.
  """
  use Barkpark.DataCase, async: false

  alias Barkpark.Repo
  alias Barkpark.Tenancy.WorkspaceBundle.Catalog

  @mirror_table "zzz_connector_config_mirror"

  # ALWAYS schema-qualify: the real `chat_bridge.connector_installs` exists in
  # this DB (test_helper creates it), and an unqualified DROP would resolve by
  # search_path. Every mutation here is a `public` one and dies a `public` one.

  defp drop!(name), do: Repo.query!("DROP TABLE IF EXISTS public.#{name}", [])

  describe "connector credential exclusion is an explicit deny (task-fff1116564723b60)" do
    test "the deny names connector_installs AND its sealed reference columns" do
      assert "connector_installs" in Catalog.credential_denied_tables()

      assert Enum.sort(Catalog.credential_denied_columns()) ==
               ~w(chat_token_ref credential_ref),
             "the sealed reference columns are the shape half of the deny — a renamed " <>
               "mirror must still be caught"
    end

    test "the clean schema passes, and no bundle path can see connector_installs" do
      assert :ok = Catalog.assert_connector_credential_exclusion!(Repo)
      assert :ok = Catalog.assert_partition!(Repo)
      assert :ok = Catalog.assert_dev_partition!(Repo)

      refute "connector_installs" in Catalog.live_base_tables(Repo)
      refute "connector_installs" in Catalog.live_e1(Repo)
      refute "connector_installs" in Catalog.live_e2(Repo)
      refute "connector_installs" in Catalog.live_e3(Repo)
      refute Map.has_key?(Catalog.allowlist(), "connector_installs")
      refute Map.has_key?(Catalog.dev_partition(), "connector_installs")

      # Fail-closed: even if it somehow became reachable, the dev profile would
      # never copy it. That is defense in depth, NOT the guard under test.
      assert Catalog.dev_action("connector_installs") == :deny
    end
  end

  describe "the tripwire reds BEFORE any bundle is accepted (C1)" do
    test "a public.connector_installs table RAISES from both partition sentinels" do
      assert :ok = Catalog.assert_partition!(Repo)

      Repo.query!(
        """
        CREATE TABLE public.connector_installs (
          provider text NOT NULL,
          install_key text NOT NULL,
          workspace_id text,
          credential_ref text,
          chat_token_ref text,
          created_at timestamptz,
          PRIMARY KEY (provider, install_key)
        )
        """,
        []
      )

      try do
        assert "connector_installs" in Catalog.live_base_tables(Repo),
               "the mutation must actually land, or this proves nothing"

        for {label, fun} <- [
              {"direct", fn -> Catalog.assert_connector_credential_exclusion!(Repo) end},
              {"full-fidelity sentinel", fn -> Catalog.assert_partition!(Repo) end},
              {"dev sentinel", fn -> Catalog.assert_dev_partition!(Repo) end}
            ] do
          error = assert_raise RuntimeError, fun

          assert error.message =~ "connector_installs",
                 "#{label}: the refusal must NAME the table"

          assert error.message =~ "credential_ref" and error.message =~ "chat_token_ref",
                 "#{label}: the refusal must name the sealed columns"

          assert error.message =~ "chat_bridge",
                 "#{label}: the refusal must state WHY (the namespace accident)"
        end
      after
        drop!("connector_installs")
      end

      assert :ok = Catalog.assert_partition!(Repo)
      assert :ok = Catalog.assert_dev_partition!(Repo)
    end

    test "a RENAMED public mirror of the sealed columns RAISES too (shape half)" do
      assert :ok = Catalog.assert_connector_credential_exclusion!(Repo)

      Repo.query!(
        """
        CREATE TABLE public.#{@mirror_table} (
          id uuid PRIMARY KEY,
          workspace_id uuid,
          credential_ref text,
          chat_token_ref text
        )
        """,
        []
      )

      try do
        error =
          assert_raise RuntimeError, fn ->
            Catalog.assert_connector_credential_exclusion!(Repo)
          end

        assert error.message =~ @mirror_table,
               "a mirror under another name must still be named in the refusal"
      after
        drop!(@mirror_table)
      end

      assert :ok = Catalog.assert_connector_credential_exclusion!(Repo)
    end

    test "the NAME half fires on its own, with no sealed column present" do
      # Isolates the name half from the shape half: a `public.connector_installs`
      # that carries none of the sealed columns yet must still be refused, because
      # the bridge is the only writer and a public table under that name means the
      # namespace wall has moved. Emptying `credential_denied_tables/0` reds this
      # test and nothing else.
      Repo.query!("CREATE TABLE public.connector_installs (id uuid PRIMARY KEY)", [])

      try do
        error =
          assert_raise RuntimeError, fn ->
            Catalog.assert_connector_credential_exclusion!(Repo)
          end

        assert error.message =~ "denied name"
      after
        drop!("connector_installs")
      end

      assert :ok = Catalog.assert_connector_credential_exclusion!(Repo)
    end

    test "a public relation carrying only ONE sealed column is not enough to fire" do
      # Non-vacuity in the other direction: the shape half keys on the WHOLE
      # sealed set, so an unrelated table that happens to own a `credential_ref`
      # column does not red the gate (which would make the guard get disabled).
      Repo.query!(
        "CREATE TABLE public.zzz_half_shape (id uuid PRIMARY KEY, credential_ref text)",
        []
      )

      try do
        assert :ok = Catalog.assert_connector_credential_exclusion!(Repo)
      after
        drop!("zzz_half_shape")
      end
    end
  end

  describe "positive control: ordinary public workspace tables still export (C2)" do
    test "documents remains cataloged, classified and copy-classified" do
      assert "documents" in Catalog.live_base_tables(Repo)
      assert "documents" in Catalog.live_e1(Repo)
      assert Map.has_key?(Catalog.dev_partition(), "documents")
      assert Catalog.dev_action("documents") == :copy
      assert "documents" in Catalog.dev_copy_tables()
    end

    test "the guard does not narrow the catalog while a denied mirror exists" do
      Repo.query!(
        """
        CREATE TABLE public.#{@mirror_table} (
          id uuid PRIMARY KEY,
          credential_ref text,
          chat_token_ref text
        )
        """,
        []
      )

      try do
        # The credential gate is red...
        assert_raise RuntimeError, fn ->
          Catalog.assert_connector_credential_exclusion!(Repo)
        end

        # ...and the ordinary catalog is untouched: `documents` is still there.
        assert "documents" in Catalog.live_e1(Repo)
        assert Catalog.dev_action("documents") == :copy
      after
        drop!(@mirror_table)
      end

      assert :ok = Catalog.assert_partition!(Repo)
    end
  end
end
