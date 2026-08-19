# cch-w35 capabilities-mint-verb re-derivation (2026-08-17)

Claim: GET /v1/capabilities exposes NO chat-token-mint verb. The only token-mint
verb is `token create`, restricted to `public-read|read` permissions ONLY (cannot
mint a `["chat"]`+workspace_id ApiToken). `chat create-session` mints identities
SERVER-side, not a CLI-mintable chat token. D33 rules a self-serve chat-token mint
endpoint "optional P3 polish (backlog)" — already adjudicated a non-gap.

Rerun:

    bp capabilities -o json > /tmp/caps_live.json
    python3 -c "import json; d=json.load(open('/tmp/caps_live.json')); cmds=d['commands']; print([ (c[0],c[1],c[2]) for c in cmds if 'mint' in ' '.join(map(str,c[:3])).lower() ])"
    # -> ('token','create','Mint a read-only ... public-read/read only'),
    #    ('ticket-key','mint',...), ('airdrop','mint'|create...), none = chat ApiToken mint
    python3 -c "import json,sys; d=json.load(open('/tmp/caps_live.json')); import re; print([c for c in d['commands'] if c[0]=='token' and c[1]=='create'])"
    # token.create flags: permissions = 'public-read|read ONLY (default public-read)'

Charter D33 (adjudicates the row):

    grep -n 'D33' .claude/workflows/bp-connectors-charter.md
    # 71: "A self-serve chat-token mint endpoint is optional P3 polish (backlog...)"

install.ex line ~15 (origin/main) confirms Studio-side minting:

    git show origin/main:api/lib/barkpark/connectors/install.ex | sed -n '15,17p'
    # "* Studio mints + revokes api_tokens (Barkpark's OWN table)."
