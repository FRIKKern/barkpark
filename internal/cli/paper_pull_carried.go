package cli

import "github.com/FRIKKern/barkpark/internal/apiclient"

// pullCarried names every list item the pulled BPML does not show all of,
// which a push carries back from the stored paper (task-0b448ea0847a6b4f).
// The pull answers the whole count; when it is above 0 a second read names
// each item. The pull and that read are two requests, so bp compares their
// x-paper-rev and x-bpml-view: the read must answer both, equal to the
// pull's, and name as many items as the count, or the pull writes nothing
// and says which differ. A server that sends no count (count -1) names none.
func pullCarried(out *writer, client *apiclient.Client, slug string, count int, rev, view string) ([]apiclient.PaperCarriedItem, int) {
	if count <= 0 {
		return []apiclient.PaperCarriedItem{}, exitOK
	}

	items, named, crev, cview, apiErr, err := client.PaperCarried(slug)
	if err != nil {
		out.userErr("paper pull %s: %v", slug, err)
		return nil, exitGeneric
	}
	if apiErr != nil {
		renderPaperAPIErr(out, "pull "+slug, apiErr)
		return nil, exitGeneric
	}
	if crev == "" || cview == "" || crev != rev || cview != view {
		out.userErr("paper pull %s: the pull and the carried read are not one view "+
			"(pull: rev %q, view %q; carried read: rev %q, view %q); nothing was written, pull again",
			slug, rev, view, crev, cview)
		return nil, exitGeneric
	}
	if named != count || len(items) != count {
		out.userErr("paper pull %s: the server counted %d carried items and named %d; nothing was written", slug, count, len(items))
		return nil, exitGeneric
	}
	return items, exitOK
}

// printCarried prints one line per carried item, after the pulled line.
func printCarried(out *writer, items []apiclient.PaperCarriedItem) {
	if len(items) == 0 {
		return
	}
	out.outf("%d list items hold what this copy does not show; a push keeps it:", len(items))
	for _, it := range items {
		out.outf("  carried, not printed: block %s, item %s", it.Block, it.Item)
	}
}
