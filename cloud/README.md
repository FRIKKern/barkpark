<!-- doc-tier: human | canonical-for: barkpark-cloud-control-plane | budget: 200tok -->

# Barkpark Cloud

The **control plane** for Barkpark Cloud: a small, standalone Elixir + Ecto app that stores *metadata* about many independent Barkpark Postgres instances — who owns which instance, where it lives, its lifecycle state. It is deliberately separate from `api/` because it must outlive any single Barkpark instance and never holds customer content, only metadata.

Boot it:

```bash
cd cloud
mix deps.get && mix ecto.setup && mix run
```

`mix ecto.setup` creates `barkpark_cloud_dev` and runs the baseline migration. This skeleton brings up just the Ecto Repo and a `BarkparkCloud.Health.health/0` liveness probe; identity (cloud-8) and the instance registry (cloud-9) land in later tasks.
