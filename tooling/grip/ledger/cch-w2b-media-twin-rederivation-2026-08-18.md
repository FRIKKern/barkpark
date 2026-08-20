# V4 media-twin re-derivation recipe (wave 2b, origin/main 3ddc00a0)

Confirms the media surface carries BOTH search-tenancy holes structurally identical
to the documents surface, and the fix is literally the same patch.

## Door-1 media (unguarded synonym writes) — v1/media_controller.ex

    git show origin/main:api/lib/barkpark_web/controllers/v1/media_controller.ex \
      | grep -nE 'create_search_synonym|promote_search_synonym|delete_search_synonym|token_workspace_id|nil_workspace_write_error'

Expect: create@127 promote@137 delete@185 all call `Synonyms.<op>("media",dataset,params,workspace_id(conn))`
with NO `case token_workspace_id(conn)` guard; only update_search_settings@163 has the guard (case@170).
Helpers: token_workspace_id/1 @571, nil_workspace_write_error/1 @581.

Helper-name / body match vs search_controller.ex (the Door-1 template):

    git show origin/main:api/lib/barkpark_web/controllers/search_controller.ex   | sed -n '467,485p'
    git show origin/main:api/lib/barkpark_web/controllers/v1/media_controller.ex | sed -n '571,589p'

Expect: BYTE-IDENTICAL helper bodies (token_workspace_id reads conn.assigns[:api_token].workspace_id;
nil_workspace_write_error emits emit_custom 422 "unprocessable" same message). => media copy is the same patch.

## Door-2 media (flat block collapses to Default) — router.ex

    git show origin/main:api/lib/barkpark_web/router.ex | sed -n '2166,2182p'

Expect: media settings pair @2166-2170 already on `pipe_through(:search_settings_admin)`;
flat synonyms/insights block @2173-2182 on `pipe_through([:api, :require_admin])`.
Door-2 fix = one-line flip of 2174 to `:search_settings_admin` (mirrors documents flat block @1974).
Disjoint from documents flat block (1965-1982). Scoped media twins already exist @2478-2486 (scoped_api/scoped_admin).

## Charter rows treating documents+media as ONE unit

    git show origin/main:.claude/workflows/bp-cloud-build-charter.md | grep -nE '\*\*D45|\*\*D58|\*\*D71|\*\*D74'

D45@87 "bleed spans BOTH documents AND media (media_controller.ex:150,156)";
D58@110 "docs + media" settings actions attribute to token workspace;
D71@133 "Covers BOTH documents AND media";
D74@136 fail-closed-422 "in the two settings WRITE actions (docs+media)".
