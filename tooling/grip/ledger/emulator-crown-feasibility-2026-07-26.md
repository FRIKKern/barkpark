# Re-derivation: Tier-C emulator crown evidence IS autonomously runnable (2026-07-26)

Verdict: **crown proof gets real emulator screenshots + machine text assertions this wave**,
no human gate touched. `mob-hg-device-boot` is a PHYSICAL-device packet (charter D34/D43);
the `bpspike` emulator has never been part of it.

## Env (nothing is on PATH — always absolute)

```sh
export SDK=/opt/homebrew/share/android-commandlinetools
export JAVA_HOME=/opt/homebrew/opt/openjdk@17          # keg-only, NOT linked; `java` is absent from PATH
export ANDROID_HOME=$SDK ANDROID_SDK_ROOT=$SDK
PT=$SDK/platform-tools/adb
```

## 1. Emulator (already up as of this run — 7h19m, launched with the charter's own flags)

```sh
$SDK/emulator/emulator -avd bpspike -no-window -no-audio -no-boot-anim &   # cold
$PT wait-for-device shell getprop sys.boot_completed                        # -> 1
$PT devices                                                                 # -> emulator-5554 device
$PT shell pm list packages | grep -i bark                                    # -> package:cloud.barkpark.mobile
```

## 2. THE BLOCKER, and the env-only fix (must be in every build slice's recipe)

`:app:createBundleReleaseJsAndAssets` passes `--reset-cache`, and the fresh Metro transformer
worker cannot resolve `babel-preset-expo` (pnpm: it lives only in `node_modules/.pnpm/…`,
linked into neither `node_modules/` nor `apps/mobile/node_modules/`). Without `--reset-cache`
the same bundle succeeds — so this is invisible to a hand-run `expo export:embed`.

```sh
export NODE_PATH=$(ls -d /Volumes/SATECHI/github/barkpark/node_modules/.pnpm/babel-preset-expo@*/node_modules)
```

Fail-before / fail-after (one command, decisive):

```sh
cd /Volumes/SATECHI/github/barkpark/apps/mobile/android && ./gradlew :app:assembleRelease --offline
#   without NODE_PATH -> "Failed to construct transformer: Cannot find module 'babel-preset-expo'" BUILD FAILED
#   with    NODE_PATH -> "Android Bundled 6192ms apps/mobile/index.ts (714 modules)" BUILD SUCCESSFUL in 20s
```

Durable alternative for a slice (not required for the harness): add `babel-preset-expo` to
`apps/mobile` devDependencies, or a root `.npmrc` `public-hoist-pattern[]=babel-preset-expo`
(there is no `.npmrc` at the repo root today).

## 3. Build → install → launch → evidence (whole loop, ~40s warm)

```sh
$PT install -r app/build/outputs/apk/release/app-release.apk      # -> Success; MMKV session SURVIVES
$PT shell am start -n cloud.barkpark.mobile/.MainActivity
$PT exec-out screencap -p > /tmp/shot.png                          # 1080x2400 PNG
$PT exec-out uiautomator dump /dev/tty > /tmp/ui.xml              # RN Text IS exposed as text="…"
```

## 4. The mechanical crown oracle (better than a screenshot)

`blocks.tsx:879-899` renders the fallback as the literal string `Unsupported block: <type>`,
so the "0 unknown blocks" claim is assertable, not eyeballed:

```sh
$PT exec-out uiautomator dump /dev/tty | grep -o 'Unsupported block: [^"<]*' | sort -u   # must be EMPTY
```

## 5. Navigation without deep links

The app registers no URL routes (`scheme: barkpark` in app.json is unused — no `Linking.useURL`
/ router). Drive it with `input tap`: tab bar at y=2310 (Tasks 180 / Chat 540 / Papers 898),
list row 1 at ~(540,420). Papers is recency-ordered, so **a freshly published crown paper is
row 1** — one tap, no scrolling through 549 papers. Proven this run: tapped Papers → tapped
row 1 → the reader painted and `uiautomator` returned full paragraph text.

## 6. Residual (Decide must scope it)

Reader register is fully drivable. The **chat** register needs a transcript that already
contains the blocks; only chart+heatmap are chat-arrivable and a real send is D41 territory.
Either seed a session server-side or land a dev-only harness route — do not assume tapping
gets you there.

## Facts worth not re-deriving

- Mobile jest baseline green: `cd apps/mobile && npx jest` -> `30 suites / 456 tests passed` in 1.8s.
- Installed build is RELEASE, non-debuggable (`run-as` -> "package not debuggable"), so JS
  changes require the 20s gradle loop; Metro hot reload would need a debug variant that has
  never been built here.
- Gradle 9.3.1 wrapper dist + ~3.2 GB `~/.gradle` cache are warm; `--offline` works.
