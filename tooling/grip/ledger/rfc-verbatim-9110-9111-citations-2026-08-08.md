# RFC verbatim — 9110/9111 citation re-derivation recipes (http-edge-truth W1)

Fetch once:

    curl -s -o /tmp/rfc9110.txt https://www.rfc-editor.org/rfc/rfc9110.txt
    curl -s -o /tmp/rfc9111.txt https://www.rfc-editor.org/rfc/rfc9111.txt

Both are STD-track, June 2022 (RFC 9110 = STD 97 "HTTP Semantics"; RFC 9111 = STD 98 "HTTP Caching").
Line numbers below are of the plain-text renderings fetched above.

| Citation | Heading (verbatim) | Re-derive |
|---|---|---|
| 9110 §13.1.2 | If-None-Match | `sed -n '5872,5942p' /tmp/rfc9110.txt` |
| 9110 §8.8.1 | Weak versus Strong | `sed -n '3393,3480p' /tmp/rfc9110.txt` |
| 9110 §8.8.3.2 | Comparison (strong/weak entity-tag comparison + Table 3) | `sed -n '3643,3672p' /tmp/rfc9110.txt` |
| 9110 §13.2.2 | Precedence of Preconditions (INM = step 3, IMS = step 4) | `sed -n '6222,6288p' /tmp/rfc9110.txt` |
| 9110 §15.4.5 | 304 Not Modified | `sed -n '7444,7480p' /tmp/rfc9110.txt` |
| 9110 §8.2 | Representation Metadata | `sed -n '2919,2928p' /tmp/rfc9110.txt` |
| 9111 §3.1 | Storing Header and Trailer Fields | `sed -n '338,368p' /tmp/rfc9111.txt` |
| 9111 §3.2 | Updating Stored Header Fields | `sed -n '369,415p' /tmp/rfc9111.txt` |
| 9111 §3.5 | Storing Responses to Authenticated Requests | `sed -n '453,465p' /tmp/rfc9111.txt` |
| 9111 §4.2.2 | Calculating Heuristic Freshness | `sed -n '686,700p' /tmp/rfc9111.txt` |
| 9111 §4.3.2 | Handling a Received Validation Request | `sed -n '866,929p' /tmp/rfc9111.txt` |
| 9111 §4.3.3 | Handling a Validation Response | `sed -n '930,950p' /tmp/rfc9111.txt` |
| 9111 §4.3.4 | Freshening Stored Responses upon Validation | `sed -n '951,989p' /tmp/rfc9111.txt` |
| 9111 §5.2.2.2 | must-revalidate | `sed -n '1222,1245p' /tmp/rfc9111.txt` |
| 9111 §5.2.2.4 | no-cache | `sed -n '1258,1294p' /tmp/rfc9111.txt` |
| 9111 §5.2.2.5 | no-store | `sed -n '1295,1314p' /tmp/rfc9111.txt` |
| 9111 §5.2.2.7 | private | `sed -n '1321,1354p' /tmp/rfc9111.txt` |

Heading-anchored (line-number-proof) alternative:

    awk '/^13\.1\.2\.  If-None-Match/{f=1} f{print} /^13\.1\.3\./{if(f)exit}' /tmp/rfc9110.txt
    awk '/^4\.3\.4\.  Freshening/{f=1} f{print} /^4\.3\.5\./{if(f)exit}' /tmp/rfc9111.txt

## The 4.3.4 ruling (retained, not removed)

9111 §4.3.4: "For each stored response identified, the cache MUST update its header fields with the
header fields provided in the 304 (Not Modified) response, as per Section 3.2."
9111 §3.2: "the cache MUST add each header field in the provided response to the stored response,
replacing field values that are already present, with the following exceptions: ..." — the exception
list is Section 3.1's excepted fields, fields the stored response depends upon, auto-processed fields,
and Content-Length. **Nothing removes a stored header merely because it is absent from the 304.**
Only removal path in the spec: the QUALIFIED forms of `no-cache` / `private` (§5.2.2.4 / §5.2.2.7),
which name fields to exclude.
