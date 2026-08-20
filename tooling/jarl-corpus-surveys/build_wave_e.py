#!/usr/bin/env python3
import json, os, collections

D = "/private/tmp/claude-501/-Users-frikkjarl-Documents-GitHub/2938d290-edae-40dd-bce3-1286cec080a8/scratchpad/corpus-surveys"

OWNERS = {
    "frikkern": "FRIKKern",
    "guerrilla": "Guerrilla-Interactive",
    "codehouseno": "codehouseno",
    "Umble-tech": "Umble-tech",
    "inligo-as": "inligo-as",
    "kult-byra": "kult-byra",
    "GyldendalDigital": "GyldendalDigital",
    "pelle-jarl": "pelle-jarl",
}

# Actual local clones (ls of /Users/frikkjarl/Documents/GitHub), plus name aliases
# verified via git remote: portable-doc-mvp->portable-doc, jarl-website-2023-archive->jarl-website(GI),
# pelle->pelle-jarl/pelle, oslobukta->kult-byra/oslobukta (not in any listing).
LOCAL = {x.lower() for x in [
    "AG-Horizon-App","Akerbrygge","Kronprinsparets-fond","Lunnheim","Myhre-Smie","Nextgen-CLI",
    "Nextgen-UI","PacePush","ag-horizon","ai-training-folder","aquatiq","astro-boilerplate",
    "barkpark","develon-connect","dnd-combat-ui","doey","flyt-programmet",
    "frick-elementor-logo-carousel-plugin","frick-monorepo","frickin-real-time","galleryspace",
    "gyldendal.no","hundesteder","hvordan-skrive-bok","jarl-website","kobber-editor","kobber-shadcn",
    "kppf-studio","kronprinsparets-fond-monorepo","lunnheim-2023","next-13-sanity-boiler",
    "next-sanity-boilerplate","next-sanity-standard-nextgen-cli-example","nextgen-commander",
    "nextgen-go-cli","nextgen-liveblocks","nextgen-markers","nextgen-on-wails","nextgen-theme",
    "nextgen-vscode","ng","ngo","ngui","noo-noo","openclaw-handoff","oslobukta","paperflow",
    "polyflor-app","polyflor-next-order-app-2024","portable-doc","pwdr-horizon",
    "runeguide-wow-classic-sod","schema-ui-test","sheets-node","slappa-sanity","soyr-sanity",
    "soyr-turbo","starter-lun","svg-animate-check","testgen-3","testgen-5","testgen-9",
    "unge-venstre","wow-classic-sod-guide",
]}
# pelle-jarl/pelle is the local clone; FRIKKern/pelle is a DIFFERENT project (remote-only).
LOCAL_QUALIFIED = {("pelle-jarl", "pelle")}
NOT_LOCAL_DESPITE_NAME = {("FRIKKern", "pelle")}
# FRIKKern/next-sanity-boilerplate: local tracks the Guerrilla one; FRIKKern copy remote-only.
NOT_LOCAL_DESPITE_NAME.add(("FRIKKern", "next-sanity-boilerplate"))
# FRIKKern/jarl-website is local (2026); Guerrilla jarl-website is the local 2023 archive. Both local.

PROMOTE = {
    ("FRIKKern","ticket-realtime"): "complete AI email-to-PR automation system (Resend+Convex+Next16+GitHub App, dual LLM), 37MB, never cloned locally",
    ("FRIKKern","co-lab"): "finished Next.js+Barkpark starter with FagPrat classroom game and live Vercel demo — the flagship Barkpark consumer example",
    ("FRIKKern","pelle"): "distinct project from local pelle-jarl/pelle: Go voice-activated Claude Code orchestrator (wake word 'Haellae') — forgotten sibling",
    ("Guerrilla-Interactive","eir-2023"): "203MB Guerrilla client build (Q4 2023, TS/tRPC/Tailwind) — largest un-cloned Guerrilla repo",
    ("codehouseno","amundsen"): "58MB Sanity+Next client webshop, 2023-02 to 2025-03 — two years of client work with companion woo-plugin",
    ("codehouseno","codehouse-b2b"): "B2B WooCommerce toolkit (company accounts, role-based access), actively pushed through 2026-07",
    ("codehouseno","goldfish-backend"): "live production WP backend for my.goldfishboat.com, pushed 2026-06, plus webhook-handler satellite",
    ("codehouseno","integrations"): "active TS integrations hub, 2025-11 to 2026-07 — current client plumbing that exists nowhere locally",
    ("Umble-tech","hovinbyen"): "live client site, Frikk's own commits through 2026-05, remote-only despite being active",
    ("inligo-as","advokatsystemer-backend"): "full Django law-firm SaaS (24MB, documented API/ViewSets, 2020-2023) from the forgotten Inligo AS company; pairs with -frontend",
}

DOSSIER = {
    # FRIKKern — WoW addon family
    ("FRIKKern","AutoCollapseBuffs"): "published WoW addon (BuffFrame auto-hide)",
    ("FRIKKern","AutoQue"): "published WoW addon (auto role-check accept), pushed 2025-08",
    ("FRIKKern","LossPunishment"): "WoW addon experiment 2025-05",
    ("FRIKKern","PoisonPal"): "WoW Midnight rogue addon 2026-03",
    ("FRIKKern","DamageBrother"): "WoW addon 2023",
    ("FRIKKern","HypeNumbers"): "private WoW addon, 2MB, 2024",
    ("FRIKKern","WoW-Midnight-Addon-Template"): "WoW Midnight 12.0 addon dev docs+template, 2026",
    ("FRIKKern","Better-Addons-WoW-Template"): "production WoW addon template, 2026",
    ("FRIKKern","better-addons"): "AI-powered WoW addon toolkit for Claude Code, 2026",
    ("FRIKKern","wow-classic-sod-runes"): "companion to local wow-classic-sod-guide",
    # FRIKKern — client/agency history
    ("FRIKKern","polyflor.se"): "97MB Polyflor Sweden WordPress site 2023 — Polyflor prehistory",
    ("FRIKKern","polyflor-projects"): "Polyflor WP projects 2022",
    ("FRIKKern","modino-samsung-campaign-wordpress"): "46MB Samsung campaign WP build 2023",
    ("FRIKKern","samsung-campaign-2023"): "43MB Samsung campaign 2023",
    ("FRIKKern","stl-wordpress"): "24MB public WP build 2025-06",
    ("FRIKKern","rett"): "27MB PHP build from 2019 — earliest substantial own work",
    # FRIKKern — product attempts / tooling
    ("FRIKKern","Nexthole"): "Nexthole project cluster 2021 (with -Website and nexthole-web, 30MB)",
    ("FRIKKern","nexthole-web"): "Nexthole web app 30MB, 2021",
    ("FRIKKern","hyperfocus"): "2021 product attempt (with hyperfocus-2)",
    ("FRIKKern","pagebuilder"): "2021-2022 pagebuilder, 5.6MB",
    ("FRIKKern","spin-off-next"): "39MB Spin-off project 2021 (Guerrilla copies exist too)",
    ("FRIKKern","gry-galleryspace"): "gallery variant for Gry, 2020-12",
    ("FRIKKern","doey-code"): "Go Bubble Tea Claude Code harness experiment 2026-04",
    ("FRIKKern","pi-flow"): "Pi harness experiment (Composer 2.5 via Cursor) 2026-05",
    ("FRIKKern","jarl-card"): "single-file ASCII-storm digital business card, 2026-07",
    ("FRIKKern","barkpark-next-starter"): "public Next.js+Barkpark starter",
    ("FRIKKern","homebrew-tap"): "Homebrew tap for noo-noo",
    ("FRIKKern","norsk-puls"): "8MB TS project 2026-03; duplicate copy on pelle-jarl org",
    ("FRIKKern","asda"): "throwaway Barkpark clone (probe-era scratch), July 2026",
    ("FRIKKern","hola"): "throwaway Barkpark clone (probe-era scratch), July 2026",
    ("FRIKKern","bulk-discount-codes-import"): "Shopify CSV discount-code import app 2025-11",
    ("FRIKKern","ticket-realtime"): "",  # promoted; placeholder never used
    # Guerrilla
    ("Guerrilla-Interactive","betongparker"): "Betongparker client project cluster 2022 (with -Map, map-next, map-sanity)",
    ("Guerrilla-Interactive","Betongparker-Map"): "Betongparker map app, TS, 2022",
    ("Guerrilla-Interactive","Wilhelmsen-HR"): "Wilhelmsen HR client build 2022",
    ("Guerrilla-Interactive","Kontorstrekken"): "Flutter office-exercise app 2022",
    ("Guerrilla-Interactive","skikurs"): "12MB public ski-course site 2021",
    ("Guerrilla-Interactive","slappa-flutter"): "Flutter companion to local slappa-sanity",
    ("Guerrilla-Interactive","spin-off-next"): "Spin-off 2022 iteration, 29MB (also spinoff-clone)",
    ("Guerrilla-Interactive","lunnheim-coming-soon"): "Lunnheim satellite 2023",
    ("Guerrilla-Interactive","stripe-lunnheim"): "Lunnheim Stripe integration 2023",
    ("Guerrilla-Interactive","hovin-studio"): "recent studio work 2025-06 to 2025-11",
    ("Guerrilla-Interactive","nm-i-ai-2026"): "NM i AI 2026 competition entry (Python); kult-byra/nm-ai is sibling",
    ("Guerrilla-Interactive","nextgen"): "origin of the nextgen CLI saga, 2021-12",
    ("Guerrilla-Interactive","nextgen-kit"): "nextgen iteration 2023",
    ("Guerrilla-Interactive","nextgen-wordpress-theme"): "nextgen WP theme 7.5MB, 2025-01",
    ("Guerrilla-Interactive","Nextgen-Copy-Paste-JSON"): "public nextgen JSON tool, 6MB, 2025-01",
    ("Guerrilla-Interactive","sanity-plugin-sitemap"): "Sanity sitemap plugin 2023",
    ("Guerrilla-Interactive","spreadsheet-wizard"): "spreadsheet export tool — companion to local sheets-node",
    ("Guerrilla-Interactive","wordpress-campaign-manager"): "WP campaign manager tooling 2023",
    ("Guerrilla-Interactive","samsung-kampanje"): "Samsung campaign 2023 (Guerrilla side)",
    ("Guerrilla-Interactive","eir-2023"): "",  # promoted
    # codehouseno
    ("codehouseno","amundsen-woo-plugin"): "41MB React product configurator Woo plugin for Amundsen",
    ("codehouseno","sleepers"): "Sleepers client project 2023-2025",
    ("codehouseno","sleepersb2b"): "Sleepers B2B PHP, 2026 — sibling of codehouse-b2b",
    ("codehouseno","wooreact"): "WooCommerce+React experiments 2022-2023",
    ("codehouseno","pimhandler"): "PIM handler service 2022-2023",
    ("codehouseno","goldfish-webhok-handler"): "Goldfish webhook handler (WP customer/build creation)",
    ("codehouseno","optim-heritage"): "Shopify Liquid theme, active to 2026-07",
    ("codehouseno","optim-static"): "70MB static export 2025",
    ("codehouseno","pwdr-static"): "138MB PWDR Wear static site 2025",
    ("codehouseno","pwdrwear-prestige"): "PWDR Prestige Shopify theme 2025",
    ("codehouseno","halite-motion"): "Shopify Liquid theme 2026-01",
    ("codehouseno","akselgresvig-static"): "143MB Aksel Gresvig static site 2025",
    ("codehouseno","google-sheets-cms"): "Sheets-as-CMS experiment 2025-09",
    ("codehouseno","griptel_wc_plugin"): "public Woo PO-order sync plugin for Griptel",
    ("codehouseno","griptel-cloud-function"): "Griptel cloud function 2023-2024",
    ("codehouseno","Currency-by-Country"): "Woo currency plugin 2024",
    # Umble-tech
    ("Umble-tech","umble"): "the agency's own Gatsby site, 41MB, 2019-2022",
    ("Umble-tech","umble-2.0"): "agency site rebuild 2022-2023",
    ("Umble-tech","Vitenskapsfestival"): "210MB festival site 2021-2022 (colleague-authored; +studio repo)",
    ("Umble-tech","oslo-bukta"): "Oslobukta predecessor 24MB 2020-2021 (current site lives at inaccessible kult-byra/oslobukta)",
    ("Umble-tech","oslobukta-studio"): "Oslobukta Sanity studio, pushed to 2024-06",
    ("Umble-tech","oslobukta-festival"): "Oslobukta festival site 2021-2022",
    ("Umble-tech","city-guide"): "Oslobukta city guide 2020",
    ("Umble-tech","economy-prognosis"): "55MB Next.js economy-prognosis tool 2023-2024",
    ("Umble-tech","Ulvulv"): "Ulvulv client site 28MB 2021-2022 (+studio)",
    ("Umble-tech","Ryddi"): "Ryddi website 2021-2023",
    ("Umble-tech","Hoopit-Landingpage"): "51MB Hoopit landing 2019 — among the oldest work",
    ("Umble-tech","e-dugnad"): "Hoopit e-dugnad concept test 2020",
    ("Umble-tech","Baoagotchi"): "collaborative Tamagotchi, 2019-10 — earliest own creative project",
    ("Umble-tech","progit.no"): "Progit homepage 2020-2021",
    ("Umble-tech","the-mine"): "The Mine Trondheim landing 2021",
    ("Umble-tech","futurum-prototype"): "Futurum prototypes 2022",
    ("Umble-tech","umble-studio"): "agency Sanity studio 2020-2022",
    ("Umble-tech","umble-brand-delivery"): "brand delivery pages 2021",
    # inligo-as
    ("inligo-as","advokatsystemer-frontend"): "TS frontend of the Inligo law-firm SaaS — pairs with promoted backend",
    ("inligo-as","ungdomogfritid"): "ungdomogfritid.no client site 2021-2022",
    # kult-byra (public subset only)
    ("kult-byra","blog-generator"): "blog generator, 2020 origin, pushed 2025-02",
    ("kult-byra","electric-monk"): "agentic feature-dev tool 2026-04 (colleague-authored)",
    ("kult-byra","pi-buddy"): "Tamagotchi pet for Pi coding agent 2026-05",
    ("kult-byra","nm-ai"): "NM i AI 2026 entry (sibling of Guerrilla nm-i-ai-2026)",
    ("kult-byra","parcel-craft-docker"): "Kult's Craft+parcel+docker template",
    # GyldendalDigital (employer org, public subset; non-fork, colleague-authored)
    ("GyldendalDigital","kobber"): "Gyldendal design system — the target of local kobber-editor/kobber-shadcn",
    ("GyldendalDigital","entraptor"): "team Go middleware, Entra role check (colleague-authored)",
    ("GyldendalDigital","fakeidp"): "team fake OIDC IdP for testing (colleague-authored)",
    ("GyldendalDigital","go-pkceflow"): "team Go PKCE flow lib, July 2026 (colleague-authored)",
    ("GyldendalDigital","wails-pkceflow"): "team Wails PKCE flow, July 2026 (colleague-authored)",
    ("GyldendalDigital","lxdev"): "team LXD dev-env tool 2018-2024",
    # pelle-jarl
    ("pelle-jarl","spacetime-cms"): "art gallery CMS on SpacetimeDB 2.0 + Next 16, 2026-03",
}

NOISE_WHY = {
    ("FRIKKern","probe-automerge-clean"): "CI probe (self-labeled throwaway)",
    ("FRIKKern","probe-coe-launder"): "CI probe",
    ("pelle-jarl","norsk-puls"): "duplicate of FRIKKern/norsk-puls",
}

def why_noise(owner, r):
    k = (owner, r["name"])
    if k in NOISE_WHY: return NOISE_WHY[k]
    if r["isFork"]: return "fork"
    if r["diskUsage"] == 0: return "empty repo"
    if r["diskUsage"] < 100: return "tiny probe/experiment"
    return "abandoned experiment/boilerplate"

repos = []
per_owner_total = collections.Counter()
per_owner_remote_only = collections.Counter()
priv = pub = forks = 0
created_years = collections.Counter()
first = ("9999-99", None)
probes = 0

for f, owner in OWNERS.items():
    data = json.load(open(os.path.join(D, f + ".json")))
    per_owner_total[owner] = len(data)
    for r in data:
        name = r["name"]
        key = (owner, name)
        is_local = (name.lower() in LOCAL and key not in NOT_LOCAL_DESPITE_NAME) or key in LOCAL_QUALIFIED
        if is_local:
            continue
        per_owner_remote_only[owner] += 1
        if r["isPrivate"]: priv += 1
        else: pub += 1
        if r["isFork"]: forks += 1
        cm = r["createdAt"][0:7]
        created_years[r["createdAt"][0:4]] += 1
        if cm < first[0]: first = (cm, f"{owner}/{name}")
        if name.startswith("probe-"): probes += 1
        if key in PROMOTE:
            verdict, why = "promote", PROMOTE[key]
        elif key in DOSSIER and DOSSIER[key]:
            verdict, why = "dossier-line", DOSSIER[key]
        else:
            verdict, why = "noise", why_noise(owner, r)
        repos.append({
            "repo": name, "owner": owner,
            "created": cm, "pushed": r["pushedAt"][0:7],
            "private": r["isPrivate"], "fork": r["isFork"],
            "language": (r.get("primaryLanguage") or {}).get("name"),
            "description": r.get("description") or "",
            "verdict": verdict, "why": why,
        })

repos.sort(key=lambda x: (x["owner"], x["repo"].lower()))
vc = collections.Counter(x["verdict"] for x in repos)
busiest = max(created_years.items(), key=lambda kv: kv[1])

stats = {
    "surveyed_owners": dict(per_owner_total),
    "total_repos_listed": sum(per_owner_total.values()),
    "remote_only_per_owner": dict(per_owner_remote_only),
    "remote_only_total": len(repos),
    "remote_only_private": priv, "remote_only_public": pub, "remote_only_forks": forks,
    "verdicts": dict(vc),
    "probe_repos": probes,
    "first_ever_remote_only_repo": {"created": first[0], "repo": first[1]},
    "busiest_creation_year_remote_only": {"year": busiest[0], "repos_created": busiest[1]},
    "creation_by_year": dict(sorted(created_years.items())),
    "access_notes": [
        "kult-byra and GyldendalDigital listings show public repos only (not an org member with private read via this token); kult-byra/oslobukta (origin of local oslobukta clone) 404s for FRIKKern",
        "orgs accessible: codehouseno, Umble-tech, inligo-as, Guerrilla-Interactive; pelle-jarl is a second personal account with 3 repos",
        "local pelle tracks pelle-jarl/pelle; FRIKKern/pelle is a different project (Go voice orchestrator)",
    ],
}

out = {"stats": stats, "repos": repos}
with open(os.path.join(D, "wave-e.json"), "w") as fh:
    json.dump(out, fh, indent=1, ensure_ascii=False)
print(json.dumps(stats, indent=1))
print("promotes:", [f'{x["owner"]}/{x["repo"]}' for x in repos if x["verdict"] == "promote"])
