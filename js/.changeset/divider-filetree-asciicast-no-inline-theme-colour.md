---
"@barkpark/react": patch
---

The divider, filetree and asciicast blocks no longer put theme colours in their markup, matching the server renderer. The divider rule and the asciicast border keep their width and style inline. Their colours, the divider's § mark ground and ink, and the filetree note colours (now `bp-filetree-note--ok|soft|danger`) come from the paper-surface stylesheet. On a page that loads that stylesheet nothing changes. Rendered without it, these blocks take the host site's colours.
