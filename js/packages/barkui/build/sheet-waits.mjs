// Values the tokens sheet does not deliver yet. The check measures each one and
// records the number in proof.json; the showroom prints "waiting on the sheet"
// from that number while it is under `needs`, and the line goes by itself once
// the sheet delivers. Flip `hard` to true and the same measure fails the check.
export const SHEET_WAITS = {
  controlEdge: { label: 'control edge', needs: 3, hard: false },
}
