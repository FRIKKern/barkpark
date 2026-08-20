# Re-derivation recipes — mobile seal wave, iOS physical-boot feasibility

Scope: the human-gate packet for the physical-device boot of `apps/mobile`
(Expo SDK 57 / RN 0.86) on this host, for the 2026-07-26 closing wave of
`task-c31a4f0a6c5be3ea`. Host facts are re-derived on THIS Mac (Mac16,10, Apple M4);
repo facts are read from the working tree only where the file is untracked-free
(package.json/app.json are on main — prefer `git show origin/main:` per D20).

| # | Fact | Command |
|---|---|---|
| 1 | Host is macOS **15.5 (24F74)** — below every Xcode 26.x floor | `sw_vers` |
| 2 | **No Xcode is installed**; the active developer dir is Command Line Tools 16.4 only | `xcodebuild -version; xcode-select -p; pkgutil --pkg-info=com.apple.pkg.CLTools_Executables` |
| 3 | Xcode has **never** run here (no `~/Library/Developer/Xcode`), and **no iOS device has ever been paired** (no MobileSync backup dir) | `ls ~/Library/Developer/Xcode; ls ~/Library/Application\ Support/MobileSync/Backup` |
| 4 | **CocoaPods is absent**; system Ruby is **2.6.10**, below CocoaPods' ≥2.7.4 floor — so `gem install cocoapods` is the wrong step; `brew install cocoapods` (brew present at /opt/homebrew) is the right one | `pod --version; ruby --version; which brew rbenv rvm asdf` |
| 5 | SDK 57's prebuild template **ships an `ios/Podfile`** ⇒ CocoaPods is on the local-build path, and the template pins `platform :ios, '16.4'` | `tar tzf apps/mobile/node_modules/expo/template.tgz \| grep -i podfile; tar xzOf apps/mobile/node_modules/expo/template.tgz package/ios/Podfile \| grep -n 'platform :ios'` |
| 6 | App is **managed / CNG**: no `apps/mobile/ios`, no `eas.json` ⇒ a local build requires `expo prebuild` first | `git ls-tree origin/main apps/mobile/ --name-only` |
| 7 | Pins on main: `expo ~57.0.8`, `react-native 0.86.0`, `expo-sqlite ~57.0.1`, `react-native-mmkv ^4.3.2`, `react-native-nitro-modules ^0.36.1` — **no `expo-notifications`, no `expo-dev-client`** | `git show origin/main:apps/mobile/package.json` |
| 8 | `app.json` declares `ios.bundleIdentifier = cloud.barkpark.mobile` and **no entitlement-bearing plugins** (no push capability in the app today) | `git show origin/main:apps/mobile/app.json` |
| 9 | The OS upgrade that unblocks Xcode 26.4 **is offered right now**: macOS Tahoe 26.5.2, ~9.4 GiB; the cheap 15.7.7 hop (2.7 GiB) does **not** reach the 26.4 floor | `softwareupdate --list --no-scan` |
| 10 | Free disk is sufficient for OS + Xcode (78 Gi avail) | `df -h /` |
| 11 | Expo's **stated minimum is Xcode 26.4** ("Minimum Xcode bumped to 26.4", SDK 56 changelog; SDK 57 changelog is silent ⇒ floor inherited) | WebFetch <https://expo.dev/changelog/sdk-56> and <https://expo.dev/changelog/sdk-57> |
| 12 | **Xcode 26.4 requires macOS Tahoe 26.2+**; Xcode 26.0–26.3 require 15.6 (so 15.5 can install NO Xcode 26.x — max is Xcode 16.4) | WebFetch <https://developer.apple.com/documentation/xcode-release-notes/xcode-26_4-release-notes> (SPA, use a mirror) · <https://mungomash.com/software/xcode/versions/> · <https://dev.to/arshtechpro/xcode-264-here-is-what-actually-matters-for-devs-2hke> |
| 13 | Free provisioning (**Personal Team**) cannot sign the Push Notifications entitlement (also iCloud/App Groups/Sign in with Apple/associated domains), and its profiles **expire after 7 days** ⇒ a free boot can never retire the APNs gate | WebSearch "Personal Team unsupported capabilities push notifications entitlement"; Apple's capability matrix at <https://developer.apple.com/help/account/reference/supported-capabilities-ios/> distinguishes ADP/ADEP/free "Apple Developer" |
| 14 | **No device-boot human-gate task exists** on the epic — `mob-hg-member-seat` is the only `mob-hg-*` child | `bp task get task-c31a4f0a6c5be3ea -o json \| python3 -c "import json,sys;d=json.load(sys.stdin);[print(c['doc_id'],c.get('lifecycle_status')) for c in d['children'] if c['doc_id'].startswith('mob-hg')]"` |
| 15 | No prior art: nothing in Barkpark describes an iOS boot/Xcode packet | `bp search query "physical device boot iOS Xcode"` |
