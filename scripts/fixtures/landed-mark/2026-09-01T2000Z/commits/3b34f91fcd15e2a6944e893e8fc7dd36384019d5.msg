fix(cloud): make site-domain uniqueness bidirectional and give the name a way back (#14458)

The hostname uniqueness guard was one-directional. custom_host -> site-domain
was checked by Registry.custom_host_taken?/2 across four legs; site-domain ->
custom_host was checked by nothing. add_site_domain/2 consulted only
domain_owned_by_other_site?/2, which queries the Site table alone and never
looks at barkparks.custom_host, the provisioning FQDN, or the parent-suffix
rule. Every hardening commit landed on the custom_host side (#11708 added the
provisioning-FQDN leg, #11785 trimmed its SQL) and none on this one.

So a plain team member could create a site and attach another team's live
hostname to it, after which the unauthenticated Caddy ask-gate resolved the
victim's hostname to the attacker's site and the victim's admin got
{:error, :taken} forever. There was no route to take it back:
Registry.remove_site_domain/2 existed with zero router callers, there was no
DELETE route, and PATCH /v1/sites/:id can only touch theme, doc_type and
prebuilt_enabled. Neither the owning team nor the platform operator could free
the name.

Three parts, all tier-neutral. No existing route's enforced tier changes.

1. One predicate instead of two. add_site_domain/2 and set_custom_host/2 live
   in the same module, so the merge is legal and this is a merge rather than a
   second copy. Both now call down into hostname_claimed?/2, which holds the
   four legs once; opts carry only the self-exclusions that legitimately differ
   between the doors (:except_site_id, :except_barkpark_id, :team_id). Two
   pre-existing forks collapse as a side effect: domain_owned_by_other_site?/2
   and registered_site_domain?/1 were the same query with and without a
   self-exclusion and are now one nil-safe site_domain_claimed?/2.

2. The create door closes too. POST /v1/sites wrote body_params["domains"]
   straight into create_site/2 without ever calling add_site_domain/2, so
   fixing only the attach door would have been theatre. The check lives in
   Registry.create_site/2, where tenant safety already belongs; a hit fails the
   whole create with {:error, :domain_taken} and writes no row, and the router
   renders 409.

3. DELETE /v1/sites/:id/domains wires the previously caller-less
   remove_site_domain/2, declared user for symmetry with its inverse: releasing
   a name must never be harder than claiming it, or the fix recreates the same
   dead end at the role level.

Mutation-proved. Reverting only the new collision leg reds 5 tests; reverting
all three parts to main's behaviour reds 11 of the 14 new tests, including the
create door (201, not 409) and the delete door (404). The create-door and
DELETE tests stay green under the attach-only mutation, which is the concrete
demonstration that a test of one door proves nothing about the other.

Full cloud suite: 3996 tests, 0 failures.

Task: task-076ca42e29836029
