// Values the tokens sheet does not deliver yet. The check measures each one and
// records the number in proof.json; the showroom prints "waiting on the sheet"
// from that number while it is under `needs`, and the line goes by itself once
// the sheet delivers. Flip `hard` to true and the same measure fails the check.
//
// The lights are proved on the base surface. On the other surfaces the check
// measures drawn text and every control's boundary, and reports them here
// without turning a light off, until each line is flipped to hard. A control's
// boundary is the best of its fill and its drawn edge (border, outline, inset
// ring) against the ground, whatever token draws it; it is hard wherever the
// sheet holds 3:1, so a control that falls short turns "every skin" off. Drawn
// text is hard wherever the sheet holds 4.5:1 (raised, sunken, inverse, since the
// sheet's hover and pressed fills); it still waits on primary.
export const SHEET_WAITS = {
  boundary: { label: 'control boundary', needs: 3, hard: true },
  'text:raised': { label: 'text on raised', needs: 4.5, hard: true },
  'text:sunken': { label: 'text on sunken', needs: 4.5, hard: true },
  'text:primary': { label: 'text on primary', needs: 4.5, hard: false },
  'text:inverse': { label: 'text on inverse', needs: 4.5, hard: true },
  'boundary:raised': { label: 'control boundary on raised', needs: 3, hard: true },
  'boundary:sunken': { label: 'control boundary on sunken', needs: 3, hard: true },
  'boundary:primary': { label: 'control boundary on primary', needs: 3, hard: true },
  'boundary:inverse': { label: 'control boundary on inverse', needs: 3, hard: true },
}

/** The surface every light is proved on; the others are measured only. */
export const PROVED_ON = 'base'
