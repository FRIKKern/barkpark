---
'create-barkpark-app': patch
---

blog-starter: pin the true `totalPages` against the fudged window. The home page once over-fetched `POSTS_PER_PAGE + 1` and passed `totalPages = hasNext ? pageNum + 1 : pageNum` to `<Pagination>` — a number derived from where the reader stands rather than from how much there is, so the numbered link list grew as you paged deeper and never showed the real last page. That fudge was replaced by `pageCount(await countDocs('post'), POSTS_PER_PAGE)` as collateral of the `?page=` clamp, but nothing in the tree named the defect, so a regression back to a cursor-derived total would have shipped silently.

Test-only: no template behaviour changes. The fudge is now modelled verbatim as a control arm and contrasted page by page against the true count (on a 47-post corpus, page 3 renders `[1,2,3,4]` under the fudge and `[1..9]` under the truth, and the fudged "last page" walks with the reader while the true total stays 10), plus the two boundaries the defect hides behind: an exactly-full corpus is N pages and not N+1, and an empty corpus is one page with no control rendered.

Mutation-proved rather than present-in-file: reverting `app/page.tsx` to the fudge reds the source arm (each of its six assertions verified to fire independently), mutating `countDocs` to return `documents.length` — the same defect one layer down — reds the second arm, and a comment-only edit leaves all ten green.
