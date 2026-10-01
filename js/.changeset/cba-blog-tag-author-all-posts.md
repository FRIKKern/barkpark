---
'create-barkpark-app': patch
---

The blog starter's tag and author pages list every matching post, not only the matches among the first 100. Both pages fetched one page of posts with `getDocs` (the query route's default of 100) and filtered it in JS, so any match past the hundredth post was dropped. They now read every post with `getAllDocs`. Live result: a tag on all 133 posts went from 100 listed to 133.
