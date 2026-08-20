# related-sql-l1-proof — re-derivation recipes (wave 10, verifier)

Read-only proofs of the crown's tag-relatedness SQL on guerrilla prod
(157.180.90.121, db barkpark_prod). No writes, no index creation.

## tags_meta / slug_text columns exist + generation expr (L1)
    ssh -i ~/.ssh/barkpark_indx root@157.180.90.121 "sudo -u postgres psql -d barkpark_prod -tAc \"select column_name, is_generated, generation_expression from information_schema.columns where table_name='documents' and column_name in ('tags_meta','slug_text')\""
# tags_meta = CASE WHEN jsonb_typeof(content->'tags')='array' THEN content->'tags' ELSE '[]'::jsonb END  (byte-identical to pre-#4178 inline CASE — see git log -p documents_retriever.ex #4178)
# slug_text = COALESCE(content->>'slug','')

## tag-element shape: {tag, strength, rationale}; main_tag is content->>'main_tag' (scalar), NOT in tags_meta
    ssh ... "sudo -u postgres psql -d barkpark_prod -tAc \"select jsonb_pretty(tags_meta) from documents where jsonb_array_length(tags_meta)>2 limit 1\""

## title lives in the top-level `title` COLUMN (NEVER generated), not content->>'title' (only 15/2132 have that)
    ssh ... "sudo -u postgres psql -d barkpark_prod -tAc \"select count(*) filter (where title is not null and title<>''), count(*) from documents where jsonb_array_length(tags_meta)>0\""  # 2128/2132

## the relatedness EXPLAIN ANALYZE (compose per source id) — see /tmp/related_explain.sql pattern
# cloud paper 6c85646b (fanout 242): Execution 54.5ms, buffers hit=2903, seq scan documents 3644 rows, all cache hit
# testing paper b6bb2746 (fanout 1004): Execution 106ms, buffers hit=7837 — strength ranking collapses 1004 -> discriminating top5 (2.2,2.0,2.0,1.95,1.9)

## duplicate tag-name within one doc (double-credit risk) = 2 docs corpus-wide
    ssh ... "sudo -u postgres psql -d barkpark_prod -tAc \"select count(*) from (select id, lower(e->>'tag') t, count(*) c from documents, jsonb_array_elements(tags_meta) e where jsonb_typeof(e)='object' group by id, lower(e->>'tag') having count(*)>1) d\""

## main_tag appears as a tag in the array 2109/2110 times (bonus derivable, but no main_tag generated column -> bonus read touches content)
    ssh ... "sudo -u postgres psql -d barkpark_prod -tAc \"select count(*) filter (where mt is not null and not h), count(*) filter (where mt is not null) from (select content->>'main_tag' mt, exists(select 1 from jsonb_array_elements(tags_meta) e where lower(e->>'tag')=lower(content->>'main_tag')) h from documents where jsonb_array_length(tags_meta)>0) s\""
