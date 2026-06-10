# Profile-switched seeding lives in lib (testable, release-safe):
#   Barkpark.Seeds.run/0 — reads BARKPARK_SEED_PROFILE (demo default | clean),
#   dispatches to Barkpark.Seeds.{Demo,Clean}, then runs the shared tail
#   (plugin-schema bootstrap + search surface defaults).
Barkpark.Seeds.run()
