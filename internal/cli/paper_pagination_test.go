package cli

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strconv"
	"testing"

	"github.com/FRIKKern/barkpark/internal/apiclient"
)

func TestPaperFetchAllPaginatesPastFullPage(t *testing.T) {
	var offsets []int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		if got := query.Get("limit"); got != strconv.Itoa(paperPageSize) {
			t.Errorf("limit = %q, want %d", got, paperPageSize)
		}
		if got := query.Get("resolve"); got != "tasks" {
			t.Errorf("resolve = %q, want tasks", got)
		}

		offset, err := strconv.Atoi(query.Get("offset"))
		if err != nil {
			t.Errorf("offset = %q: %v", query.Get("offset"), err)
			http.Error(w, "bad offset", http.StatusBadRequest)
			return
		}
		offsets = append(offsets, offset)

		count := 0
		switch offset {
		case 0:
			count = paperPageSize
		case paperPageSize:
			count = 2
		default:
			t.Errorf("unexpected offset %d", offset)
		}
		documents := make([]map[string]string, count)
		for i := range documents {
			id := offset + i
			documents[i] = map[string]string{
				"_id":  fmt.Sprintf("paper-%d", id),
				"slug": fmt.Sprintf("paper-%d", id),
			}
		}
		if err := json.NewEncoder(w).Encode(map[string]any{
			"result": map[string]any{"documents": documents},
		}); err != nil {
			t.Errorf("encode response: %v", err)
		}
	}))
	defer server.Close()

	client := apiclient.New(apiclient.Config{
		BaseURL: server.URL,
		Dataset: "production",
	})
	documents, err := paperFetchAll(client, "published")
	if err != nil {
		t.Fatalf("paperFetchAll: %v", err)
	}
	if got, want := len(documents), paperPageSize+2; got != want {
		t.Fatalf("document count = %d, want %d", got, want)
	}
	if got, want := offsets, []int{0, paperPageSize}; !reflect.DeepEqual(got, want) {
		t.Fatalf("offsets = %v, want %v", got, want)
	}
}
