<!-- doc-tier: cold | canonical-for: legendary-paper-restart-verify-09 | budget: 1800tok -->
# Restart Verify 09 — Paper MIME delivery path

Assignment `restart-verify-09` tested whether a Paper-specific MIME/send path exists and produces equivalent Gmail, Outlook, and Apple Mail results. Verdict: **refuted, high confidence**.

The complete Paper call graph is HTTP-only: the plugin/router mount a GET preview, `BulldocsEmailController.show` reads the published Paper, renders blocks or legacy HTML, finalizes title/links, then sends a `text/html` HTTP response. `Render.render_document` explicitly produces bytes a backend *should send*; it does not construct or deliver a message. `BulldocsEmailHTML.finalize` only adds the title and absolutizes links.

Repository-wide mailer census found core delivery callers only for account and access-grant notifications, both unrelated text-only messages. Cloud mailer callers cover transactional notifications, alerts, and a plain-text fleet digest; its PortableDoc email type explicitly never sends. No Elixir source/test contains an `html_body` call. There is no Paper RFC5322/MIME builder, `multipart/alternative`, sender invocation, provider receipt/message ID, or Gmail/Outlook/Apple Mail capture.

The email-controller test is an HTTP HTML test: it contains no Swoosh/Mailer/deliver, HTML/text body, Message-ID, MIME-Version, multipart, or real-client assertions. One static renderer comment names Gmail/Outlook only to justify avoiding `<details>`; it is not client execution.

Therefore the hard gate is 0 valid multipart sends, 0 receipts/message IDs, and 0/24 client-width cells. Local/test mail adapters exist but no Paper path reaches them, so no credential inspection or message send was warranted. The negative contract applies uniformly to all four frozen Papers.

## Cycle payload

```json
{"assignment_id":"restart-verify-09","cycle_assignment_id":"4fc3eb42-2aef-422a-82db-7eda20f688da","verdict":"refuted","claim":"Paper-specific MIME/send path yields equivalent Gmail/Outlook/Apple Mail","commit":"cc88c7847e219b2d1911f8cd5c1d4d2775b1268f","call_graph":"Paper GET -> render_document -> finalize -> HTTP send_resp(text/html)","paper_sender":false,"multipart_html_text":"0/1","provider_receipt_message_id":"0/1","client_width_cells":"0/24","mailers_checked":{"core":"auth+grant text-only","cloud":"transactional+alerts+fleet digest text-only"},"tests":"HTTP preview only; no delivery/client proof","clients_unvisited":["gmail","outlook","apple_mail"],"mutations":0,"confidence":"high"}
```
