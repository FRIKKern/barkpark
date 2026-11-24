import { describe, expect, it } from 'vitest'
import { nearLine, timeLine } from '../check/part-time.mjs'

describe("a part's seconds against its time limit", () => {
  it("each part's line gives its seconds against its limit, and says when it used more than two thirds of it", () => {
    expect(timeLine(203400, 360000)).toBe('time: 203.4 s of its 360 s limit')
    expect(timeLine(240000, 360000)).toBe('time: 240.0 s of its 360 s limit')
    expect(timeLine(240100, 360000)).toBe('time: 240.1 s of its 360 s limit, more than two thirds of it')
    expect(timeLine(361400, 360000)).toBe('time: 361.4 s of its 360 s limit, more than two thirds of it')
  })

  it('the run names every part over two thirds of its limit, slowest first, and none at or under it', () => {
    expect(nearLine({ button: 317900, checkbox: 361400, dialog: 344800, menu: 210700 }, 360000)).toBe(
      'time: 3 part(s) used more than two thirds of the 360 s limit: checkbox 361.4 s, dialog 344.8 s, button 317.9 s',
    )
    expect(nearLine({ button: 191500, menu: 240000 }, 360000)).toBe('time: no part used more than two thirds of the 360 s limit')
  })
})
