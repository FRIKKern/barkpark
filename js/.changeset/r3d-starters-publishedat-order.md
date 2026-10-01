---
'create-barkpark-app': patch
---

Both starters list "Latest posts" newest-published first. They read posts in the query route's default order (`_updatedAt desc`), so editing an old post moved it to the top of the home page. The website home, the blog home, and the blog tag and author pages now request `order=publishedAt:desc,_createdAt:desc`. A post with no `publishedAt` yet sorts first.
