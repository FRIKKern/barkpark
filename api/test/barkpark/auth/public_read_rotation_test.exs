defmodule Barkpark.Auth.PublicReadRotationTest do
  @moduledoc """
  task-eaaf13ab768f34f6 criterion 6: the weekly public-read rotation runs as a
  core Oban job (`Barkpark.Auth.PublicReadRotationWorker`), not a systemd timer
  that was never installed.

    * ON — a tick mints `public-read-<date>`, writes the token file (0600) and
      purges public-read rows older than 8 days, keeping the younger ones.
    * OFF (the shipped default) — a tick touches no row and no file (control).
    * FENCE — a tenant's own api token labelled `public-read-…` without the
      public-read tier survives the purge.
    * SCHEDULE — the worker sits in the static Oban crontab at Mon 03:00.
  """
  use Barkpark.DataCase, async: false

  import Ecto.Query

  alias Barkpark.Auth
  alias Barkpark.Auth.{ApiToken, PublicRead, PublicReadRotationWorker}
  alias Barkpark.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "pr-rot-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    file = Path.join(dir, "public_token")

    saved =
      for k <- ~w(PUBLIC_READ_TOKEN_FILE VERCEL_DEPLOY_HOOK),
          into: %{},
          do: {k, System.get_env(k)}

    System.put_env("PUBLIC_READ_TOKEN_FILE", file)
    System.delete_env("VERCEL_DEPLOY_HOOK")

    original = Application.get_env(:barkpark, :public_read_rotation)

    on_exit(fn ->
      Application.put_env(:barkpark, :public_read_rotation, original || [])

      for {k, v} <- saved,
          do: if(v, do: System.put_env(k, v), else: System.delete_env(k))

      File.rm_rf(dir)
    end)

    %{token_file: file}
  end

  defp switch(on), do: Application.put_env(:barkpark, :public_read_rotation, enabled: on)

  defp public_read_labels do
    Repo.all(
      from t in ApiToken,
        where: like(t.label, "public-read-%") and t.kind == "api",
        select: t.label
    )
    |> Enum.sort()
  end

  # A public-read row backdated `days` ago, as the mint path stamps it.
  defp aged_public_read!(label, days) do
    {:ok, _raw, row} = PublicRead.create_public_read_token(label)
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(t in ApiToken, where: t.id == ^row.id), set: [inserted_at: at])
    row
  end

  test "ON: a tick mints this week's token, writes the 0600 file, and purges only rows past 8 days",
       %{token_file: file} do
    switch(true)
    aged_public_read!("public-read-old", 9)
    aged_public_read!("public-read-last-week", 7)

    assert {:ok, %{label: label, purged: 1}} =
             PublicReadRotationWorker.perform(%Oban.Job{args: %{}})

    assert label == "public-read-" <> Date.to_iso8601(Date.utc_today())

    labels = public_read_labels()
    assert label in labels
    assert "public-read-last-week" in labels, "a row inside the 8-day grace was purged"
    refute "public-read-old" in labels, "a row past the 8-day grace survived"

    raw = file |> File.read!() |> String.trim()
    assert %ApiToken{label: ^label} = Repo.get_by(ApiToken, token_hash: ApiToken.hash_token(raw))
    assert Auth.has_permission?(Repo.get_by(ApiToken, label: label), "public-read")
    assert File.stat!(file).mode |> Bitwise.band(0o777) == 0o600
  end

  test "OFF (the shipped default): a tick touches no row and no file (control)", %{
    token_file: file
  } do
    refute Keyword.get(Application.get_env(:barkpark, :public_read_rotation, []), :enabled)
    aged_public_read!("public-read-old", 9)

    assert {:ok, %{skipped: :disabled}} = PublicReadRotationWorker.perform(%Oban.Job{args: %{}})
    assert public_read_labels() == ["public-read-old"]
    refute File.exists?(file)
  end

  test "the purge spares a tenant's own token that only borrows the label" do
    switch(true)

    {:ok, tenant} =
      Auth.create_token(
        "tenant-#{System.unique_integer()}",
        "public-read-my-feed",
        "production",
        ["read"],
        nil
      )

    Repo.update_all(from(t in ApiToken, where: t.id == ^tenant.id),
      set: [
        inserted_at:
          DateTime.utc_now() |> DateTime.add(-30 * 86_400, :second) |> DateTime.truncate(:second)
      ]
    )

    assert {:ok, %{purged: 0}} = PublicReadRotationWorker.perform(%Oban.Job{args: %{}})
    assert Repo.get(ApiToken, tenant.id)
  end

  test "the worker is scheduled in the Oban crontab, Mondays 03:00" do
    crontab =
      Application.get_env(:barkpark, Oban)
      |> Keyword.fetch!(:plugins)
      |> Enum.find_value([], fn
        {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
        _ -> nil
      end)

    assert {"0 3 * * 1", PublicReadRotationWorker} in crontab
  end
end
