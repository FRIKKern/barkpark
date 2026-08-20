# BARKPARK_PLUGINS="" IS the kill switch — re-derivation recipes (2026-08-08)

Verifier: self-host-blessing wave 1, assignment `plugins-kill-switch`.
Verdict: the compose comment at `docker-compose.yml:37-39` is CORRECT server-side.
Empty string (present-but-empty) → register NOTHING. Unset (nil) → discover-all.
Whitespace-only and `","` ALSO collapse to the kill switch (widening not in the comment).

## Recipes

```bash
# 1. Where the env var is read (single read site)
git grep -n 'BARKPARK_PLUGINS' origin/main -- api/

# 2. The parse function, verbatim
git show origin/main:api/lib/barkpark/plugins/env_config.ex

# 3. runtime.exs wiring (case on :unset vs list)
git show origin/main:api/config/runtime.exs | sed -n '301,316p'

# 4. The registry branch that honours [] as "load nothing"
git show origin/main:api/lib/barkpark/plugins/registry/discovery.ex | sed -n '51,60p'

# 5. Boot path proof (zero-arg call site — the env-consulting head)
git grep -n 'discover_and_register()' origin/main -- api/lib
# → api/lib/barkpark/schema_bootstrap.ex:67 (SchemaBootstrap is a supervision child,
#   api/lib/barkpark/application.ex:224)

# 6. Replicate the pure parse (no repo build needed)
elixir -e '
defmodule P do
  def parse(nil), do: :unset
  def parse(raw) when is_binary(raw) do
    raw |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == "")) |> um()
  end
  defp um([]), do: []
  defp um(n), do: if("media" in n, do: n, else: n ++ ["media"])
end
for v <- [nil, "", "   ", ",", "bulldocs,onixedit", "media"] do
  IO.puts("#{inspect(v)} -> #{inspect(P.parse(v))}")
end'
# → nil -> :unset | "" -> [] | "   " -> [] | "," -> []
#   "bulldocs,onixedit" -> ["bulldocs","onixedit","media"] | "media" -> ["media"]

# 7. Prove an empty OS env var reads as "" (not nil) in the BEAM
BARKPARK_PLUGINS= elixir -e 'IO.inspect(System.get_env("BARKPARK_PLUGINS"))'   # => ""
elixir -e 'IO.inspect(System.get_env("BARKPARK_PLUGINS"))'                      # => nil

# 8. Existing regression cover
git show origin/main:api/test/barkpark/plugins/env_config_test.exs
git show origin/main:api/test/barkpark/plugin_free_boot_test.exs | sed -n '1,40p'  # @moduletag :boot_test — EXCLUDED from default mix test
```

## Not proven here (open for Decide)

```bash
# Docker's own bare-passthrough semantics (`- BARKPARK_PLUGINS` omits when host-unset)
# could NOT be executed on this host: docker 29.6.1 is installed WITHOUT the compose plugin.
docker --version            # Docker version 29.6.1, build 8900f1d330
docker compose config       # docker: unknown command: docker compose
ls ~/.docker/cli-plugins    # No such file or directory
```

Consequence for S6/S2: the docker-side half of the hazard is undemonstrated locally —
it needs a CI runner (which has the compose plugin) to prove.
