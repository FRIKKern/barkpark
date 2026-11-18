// Values the tokens sheet does not deliver yet. The check measures each one and
// records the number in proof.json; the showroom prints "waiting on the sheet"
// from that number while it is under `needs`, and the line goes by itself once
// the sheet delivers. Flip `hard` to true and the same measure fails the check.
//
// The lights are proved on the base surface. On the other surfaces the check
// measures text against its ground and the control edge, and reports them here
// without turning a light off, until each line is flipped to hard.
export const SHEET_WAITS = {
  controlEdge: { label: 'control edge', needs: 3, hard: false },
  'text:raised': { label: 'text on raised', needs: 4.5, hard: false },
  'text:sunken': { label: 'text on sunken', needs: 4.5, hard: false },
  'text:primary': { label: 'text on primary', needs: 4.5, hard: false },
  'text:inverse': { label: 'text on inverse', needs: 4.5, hard: false },
  'controlEdge:raised': { label: 'control edge on raised', needs: 3, hard: false },
  'controlEdge:sunken': { label: 'control edge on sunken', needs: 3, hard: false },
  'controlEdge:primary': { label: 'control edge on primary', needs: 3, hard: false },
  'controlEdge:inverse': { label: 'control edge on inverse', needs: 3, hard: false },
}

/** The surface every light is proved on; the others are measured only. */
export const PROVED_ON = 'base'
