package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

// THE DEFECT. paperFetchAll ended its walk on `len(rawDocs) < paperPageSize`,
// and ZERO is a short page. A first request answered 200 `{"documents":[]}` —
// for ANY reason — broke the loop on iteration one and returned (nil, nil): an
// empty corpus with a NIL ERROR, which the caller renders as "no paper
// matches". A genuinely empty corpus, a refused request, and a truncated page
// were one response shape.
//
// MEASURED ON guerrilla 2026-09-17, all three at HTTP 200 on
// /w/default/p/default/v1/data/query/production/paper:
//
//	filter matching nothing -> {"count":0,"limit":1000,"offset":0,"hasMore":false}
//	dataset that does not exist -> {"count":0,"limit":1000,"offset":0,"hasMore":false}
//	type that does not exist    -> {"count":0,"limit":1000,"offset":0,"hasMore":false}
//	CONTROL, a corpus that exists -> {"count":3,"limit":3,"offset":0,"hasMore":true}
//
// The envelope is the only thing that can separate them, so the walk now reads
// it: hasMore LAST and UNCONDITIONALLY (pageHasMoreStated, shared with
// warnIfDefaultPageMayBeTruncated per #18684), the echoed limit as proof the
// request was honoured (pageEffectiveLimit, extended to the same two spellings),
// and a refusal when the response states neither.

// paperEnvServer serves the paper query route. pages maps the requested
// (limit, offset) to the row count to serve; envelope decides which page fields
// the response carries, so a fixture can say "the server stated nothing".
type paperPage struct {
	rows    int
	hasMore *bool
	echoLim *int
}

func paperBoolp(b bool) *bool { return &b }
func paperIntp(i int) *int    { return &i }

func paperEnvServer(t *testing.T, serve func(limit, offset int) paperPage) (*apiclient.Client, *[]string) {
	t.Helper()
	var seen []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		limit, _ := strconv.Atoi(q.Get("limit"))
		offset, _ := strconv.Atoi(q.Get("offset"))
		seen = append(seen, fmt.Sprintf("limit=%d,offset=%d", limit, offset))
		p := serve(limit, offset)
		docs := make([]map[string]string, p.rows)
		for i := range docs {
			docs[i] = map[string]string{
				"_id":  fmt.Sprintf("paper-%d", offset+i),
				"slug": fmt.Sprintf("paper-%d", offset+i),
			}
		}
		inner := map[string]any{"documents": docs, "count": len(docs), "offset": offset}
		if p.hasMore != nil {
			inner["hasMore"] = *p.hasMore
		}
		if p.echoLim != nil {
			inner["limit"] = *p.echoLim
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"result": inner})
	}))
	t.Cleanup(srv.Close)
	return apiclient.New(apiclient.Config{BaseURL: srv.URL, Dataset: "production"}), &seen
}

// THE RED ARM. Restore `if len(rawDocs) < paperPageSize { break }` in
// paperFetchAll and this test fails: the walk returns (nil, nil) and the
// t.Fatalf below fires. This is the test that FAILS if the conflation returns.
func TestPaperFetchAllRefusesAZeroPageTheServerDidNotExplain(t *testing.T) {
	t.Run("zero rows, server states NOTHING: refuse, do not answer (nil, nil)", func(t *testing.T) {
		client, seen := paperEnvServer(t, func(limit, offset int) paperPage {
			// The row's reproduction: empty at the limit the pager sends, rows
			// at a smaller one — and no page fields at all, so nothing in the
			// response distinguishes this from a drained corpus.
			if limit == paperPageSize {
				return paperPage{rows: 0}
			}
			return paperPage{rows: 5}
		})
		docs, err := paperFetchAll(client, "published")
		if err == nil {
			t.Fatalf("THE DEFECT: paperFetchAll returned (%d docs, nil error) for a 200 {\"documents\":[]} that the server never explained — a refused request rendered as an empty corpus. requests: %v", len(docs), *seen)
		}
		for _, want := range []string{"0 documents", strconv.Itoa(paperPageSize), "hasMore"} {
			if !strings.Contains(err.Error(), want) {
				t.Errorf("refusal must name %q so the reader can tell which outcome they hit; got %q", want, err)
			}
		}
	})

	t.Run("zero rows, server PROMISES more: refuse, naming the withheld page", func(t *testing.T) {
		client, _ := paperEnvServer(t, func(limit, offset int) paperPage {
			return paperPage{rows: 0, hasMore: paperBoolp(true), echoLim: paperIntp(limit)}
		})
		if docs, err := paperFetchAll(client, "published"); err == nil {
			t.Fatalf("a page withheld while the server says rows remain must not read as an empty corpus; got %d docs, nil error", len(docs))
		} else if !strings.Contains(err.Error(), "non-empty") {
			t.Errorf("refusal should say the server called the corpus non-empty; got %q", err)
		}
	})
}

// THE NEGATIVE ARM. A fix that turns every empty corpus into an error has
// traded one wrong answer for another. Both shapes the LIVE server uses to say
// "honestly nothing" must stay a nil error and an empty list.
func TestPaperFetchAllStaysQuietOnAGenuinelyEmptyCorpus(t *testing.T) {
	t.Run("hasMore:false over zero rows — the live shape", func(t *testing.T) {
		client, seen := paperEnvServer(t, func(limit, offset int) paperPage {
			return paperPage{rows: 0, hasMore: paperBoolp(false), echoLim: paperIntp(limit)}
		})
		docs, err := paperFetchAll(client, "published")
		if err != nil {
			t.Fatalf("an honestly empty corpus must not error: %v", err)
		}
		if len(docs) != 0 {
			t.Fatalf("docs = %d, want 0", len(docs))
		}
		if len(*seen) != 1 {
			t.Errorf("a stated-empty corpus must cost exactly one request; got %v", *seen)
		}
	})

	t.Run("no hasMore, but the echoed limit proves the request was honoured", func(t *testing.T) {
		client, _ := paperEnvServer(t, func(limit, offset int) paperPage {
			return paperPage{rows: 0, echoLim: paperIntp(limit)}
		})
		if docs, err := paperFetchAll(client, "published"); err != nil || len(docs) != 0 {
			t.Fatalf("server echoed the limit it applied and found nothing — that is an empty corpus, not a refusal; got %d docs, err %v", len(docs), err)
		}
	})
}

// THE TRUNCATION ARM, and the reason the fixture population must EXCEED the
// page size: a corpus smaller than one page cannot exercise a pager at all.
// The server returns a SHORT page while saying rows remain — the shape a
// byte-bounded route produces (GET /v1/data/query stops at 64MB). The old walk
// broke on the short page and reported the first partial page as the whole
// corpus.
func TestPaperFetchAllKeepsWalkingWhileTheServerSaysRowsRemain(t *testing.T) {
	const population = paperPageSize*2 + 7
	client, seen := paperEnvServer(t, func(limit, offset int) paperPage {
		remaining := population - offset
		if remaining <= 0 {
			return paperPage{rows: 0, hasMore: paperBoolp(false), echoLim: paperIntp(limit)}
		}
		// Every page comes back SHORT — bounded by bytes, not by the row limit.
		rows := limit / 2
		if rows > remaining {
			rows = remaining
		}
		return paperPage{rows: rows, hasMore: paperBoolp(rows < remaining), echoLim: paperIntp(limit)}
	})
	docs, err := paperFetchAll(client, "published")
	if err != nil {
		t.Fatalf("paperFetchAll: %v", err)
	}
	if len(docs) != population {
		t.Fatalf("SHORT PAGE READ AS THE WHOLE POPULATION: got %d of %d papers. The walk stopped on row arithmetic while the server said hasMore. requests: %v", len(docs), population, *seen)
	}
	// Offsets must advance by the rows ACTUALLY served, never by the requested
	// page size — the gap would silently skip rows.
	if (*seen)[1] != fmt.Sprintf("limit=%d,offset=%d", paperPageSize, paperPageSize/2) {
		t.Errorf("second request = %q, want offset to advance by the rows served (%d), not by the requested limit", (*seen)[1], paperPageSize/2)
	}
}

// A CLAMPED LIMIT IS NOT AN EMPTY CORPUS. If the server will not serve the
// limit asked for, it says so by echoing a smaller one; the walk retries at the
// limit the server states it honours rather than reporting zero papers.
func TestPaperFetchAllRetriesAtTheLimitTheServerHonours(t *testing.T) {
	const honoured = 25
	client, seen := paperEnvServer(t, func(limit, offset int) paperPage {
		if limit > honoured {
			return paperPage{rows: 0, echoLim: paperIntp(honoured)}
		}
		if offset >= honoured {
			return paperPage{rows: 0, hasMore: paperBoolp(false), echoLim: paperIntp(limit)}
		}
		return paperPage{rows: honoured, hasMore: paperBoolp(false), echoLim: paperIntp(limit)}
	})
	docs, err := paperFetchAll(client, "published")
	if err != nil {
		t.Fatalf("a clamped limit must be retried at the honoured limit, not reported as empty: %v", err)
	}
	if len(docs) != honoured {
		t.Fatalf("docs = %d, want %d; requests: %v", len(docs), honoured, *seen)
	}
	if len(*seen) != 2 || !strings.Contains((*seen)[1], fmt.Sprintf("limit=%d", honoured)) {
		t.Fatalf("expected a retry at limit=%d; requests: %v", honoured, *seen)
	}
}

// THE PAGE SIZE IS BOUNDED BY THE CLIENT'S OWN BYTE CAP, NOT THE SERVER'S ROW
// CLAMP. paperFetchAll sends resolve=tasks with no `fields` projection, so it
// asks for WHOLE paper bodies. Measured against guerrilla 2026-09-17 on the
// live corpus, with the exact URL paperFetchAll builds:
//
//	limit=100  -> HTTP 200,  19,569,591 bytes  (195,696 bytes/paper)
//	limit=500  -> HTTP 200,  63,595,931 bytes  (99.8% of the cap)
//	limit=1000 -> HTTP 200, 169,080,988 bytes  (2.5x the cap)
//
// doRequest reads through readCapped(maxResponseBytes = 64MB), which REFUSES an
// over-cap body outright ("response exceeds 67108864 bytes — refusing to parse
// a truncated body") — reproduced live as `bp doc query paper --limit 1000`
// exiting 1 with request_failed while `--limit 500` served 500 rows. So the old
// paperPageSize of 1000 could not complete a single request against the live
// corpus, however faithfully the server honoured the limit.
func TestPaperPageSizeFitsUnderTheClientResponseCap(t *testing.T) {
	// Measured bytes per paper at limit=100 against the live corpus, rounded up.
	const measuredBytesPerPaper = 195696
	if got := int64(paperPageSize) * measuredBytesPerPaper; got >= maxResponseBytes {
		t.Fatalf("paperPageSize=%d asks for ~%d bytes of whole paper bodies, at or over readCapped's maxResponseBytes=%d — doRequest will refuse the body and paperFetchAll cannot complete one request. Lower paperPageSize, or add a fields projection and re-measure.", paperPageSize, got, int64(maxResponseBytes))
	}
}
