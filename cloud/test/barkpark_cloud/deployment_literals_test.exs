defmodule BarkparkCloud.DeploymentLiteralsTest do
  @moduledoc """
  gh-9531 residual (task-eeabfd9bf3ed8371): the control plane's two frozen
  DEPLOYMENT values — the platform zone and the template repo — are read at CALL
  time, default to the historical literals, and FAIL CLOSED on a malformed
  configured value.

  `async: false` and every case restores the previous value: these are
  application-env reads, so a leaked override would move the zone under every
  other test in the run.
  """
  use ExUnit.Case, async: false

  alias BarkparkCloud.Registry.Barkpark
  alias BarkparkCloud.Templates

  defp put_base_domain(value) do
    previous = Application.get_env(:barkpark_cloud, :base_domain)
    Application.put_env(:barkpark_cloud, :base_domain, value)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark_cloud, :base_domain)
        prev -> Application.put_env(:barkpark_cloud, :base_domain, prev)
      end
    end)
  end

  defp put_templates_repo(value) do
    previous = Application.get_env(:barkpark_cloud, :templates_repo_url)
    Application.put_env(:barkpark_cloud, :templates_repo_url, value)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:barkpark_cloud, :templates_repo_url)
        prev -> Application.put_env(:barkpark_cloud, :templates_repo_url, prev)
      end
    end)
  end

  defp custom_host_errors(host) do
    %Barkpark{}
    |> Barkpark.custom_host_changeset(%{custom_host: host})
    |> then(fn changeset -> Keyword.get_values(changeset.errors, :custom_host) end)
    |> Enum.map(fn {message, _opts} -> message end)
  end

  describe "base_domain/0 — the platform zone (1)" do
    test "unconfigured is the historical literal" do
      assert Application.get_env(:barkpark_cloud, :base_domain) == nil
      assert Barkpark.base_domain() == "barkpark.cloud"
      assert Barkpark.base_domain() == Barkpark.default_base_domain()
    end

    test "a configured zone is honoured at call time" do
      put_base_domain("acme.test")
      assert Barkpark.base_domain() == "acme.test"
    end

    test "every URL/label derivation honours the configured zone" do
      put_base_domain("acme.test")
      pair = {"gyldendal", "71069eaa-0000-4000-8000-000000000000"}

      assert Barkpark.provisioning_fqdn(pair) == "gyldendal-71069eaa.acme.test"
      assert Barkpark.provisioning_url(pair) == "https://gyldendal-71069eaa.acme.test"
      assert Barkpark.clean_url("gyldendal") == "https://gyldendal.acme.test"

      assert Barkpark.subdomain_from_url(%Barkpark{url: "https://gyldendal.acme.test"}) ==
               "gyldendal"

      assert Barkpark.platform_custom_host?("gyldendal.acme.test")
      refute Barkpark.platform_custom_host?("gyldendal.barkpark.cloud")

      assert Barkpark.custom_host_label(%Barkpark{custom_host: "gyldendal.acme.test"}) ==
               "gyldendal"

      assert Barkpark.custom_host_label(%Barkpark{custom_host: "gyldendal.barkpark.cloud"}) == nil
    end

    test "custom_host_changeset validates against the CONFIGURED zone, not ours" do
      put_base_domain("acme.test")

      # One label under the operator's own zone: the platform shape.
      assert custom_host_errors("gyldendal.acme.test") == []

      # The operator's apex, and deeper nesting under their zone, are the two
      # verdicts that can only be reached by reading the configured value —
      # under the frozen literal both fell through to the EXTERNAL branch and
      # were accepted, so the plane's own zone was attachable as a customer FQDN.
      assert custom_host_errors("acme.test") == ["the platform apex itself cannot be attached"]

      assert custom_host_errors("deep.nested.acme.test") == [
               "must be a single label under acme.test"
             ]

      # A host under OUR old zone is now merely an external customer FQDN.
      assert custom_host_errors("gyldendal.barkpark.cloud") == []
    end

    test "the unconfigured zone keeps the historical changeset verdicts" do
      assert custom_host_errors("gyldendal.barkpark.cloud") == []

      assert custom_host_errors("barkpark.cloud") == [
               "the platform apex itself cannot be attached"
             ]

      assert custom_host_errors("deep.nested.barkpark.cloud") == [
               "must be a single label under barkpark.cloud"
             ]

      # Attach-domain V2 and the shell/Caddy-metacharacter gate are untouched.
      assert custom_host_errors("barkpark.jarl.no") == []

      assert custom_host_errors("evil host.com") == [
               "must be a well-formed lowercase fully-qualified domain"
             ]
    end

    test "FAILS CLOSED on a malformed configured zone" do
      for bad <- [
            "https://acme.test",
            "acme.test/path",
            "acme test",
            "ACME.test",
            "acme.test:4000",
            "acme.test.",
            "acme",
            "",
            :acme_test,
            123
          ] do
        put_base_domain(bad)

        assert_raise ArgumentError, ~r/invalid platform base domain/, fn ->
          Barkpark.base_domain()
        end
      end
    end
  end

  describe "templates repo (2)" do
    test "unconfigured is the upstream monorepo" do
      assert Application.get_env(:barkpark_cloud, :templates_repo_url) == nil
      assert Templates.repo() == "https://github.com/FRIKKern/barkpark"
      assert Templates.repo() == Templates.default_repo()

      assert Templates.docs() ==
               "https://github.com/FRIKKern/barkpark/blob/main/templates/MANIFEST.md"

      for template <- Templates.catalog() do
        assert template.repo == "https://github.com/FRIKKern/barkpark"

        assert template.docs ==
                 "https://github.com/FRIKKern/barkpark/blob/main/templates/MANIFEST.md"
      end
    end

    test "a fork serves its own templates — every catalog entry follows" do
      put_templates_repo("https://github.com/acme/barkpark")

      assert Templates.repo() == "https://github.com/acme/barkpark"

      assert Templates.docs() ==
               "https://github.com/acme/barkpark/blob/main/templates/MANIFEST.md"

      assert Templates.get("blog-starter").repo == "https://github.com/acme/barkpark"

      for template <- Templates.catalog() do
        assert template.repo == "https://github.com/acme/barkpark"
        assert template.docs == "https://github.com/acme/barkpark/blob/main/templates/MANIFEST.md"
      end

      # The catalog is otherwise untouched: the lock-test anchor still holds.
      assert Templates.slugs() == Enum.map(Templates.catalog(), & &1.slug)
    end

    test "FAILS CLOSED on a malformed configured repo URL" do
      for bad <- [
            "github.com/acme/barkpark",
            "ftp://github.com/acme/barkpark",
            "https://github.com/acme/barkpark/",
            "https://github.com/acme barkpark",
            "https://",
            "",
            :upstream
          ] do
        put_templates_repo(bad)

        assert_raise ArgumentError, ~r/invalid template repo URL/, fn -> Templates.repo() end
        assert_raise ArgumentError, ~r/invalid template repo URL/, fn -> Templates.catalog() end
      end
    end
  end
end
