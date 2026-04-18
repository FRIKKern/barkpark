import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { revalidateTag, revalidatePath } from 'next/cache'
import { revalidateBarkpark } from '../src/revalidate/index'

vi.mock('next/cache', () => ({
  revalidateTag: vi.fn(),
  revalidatePath: vi.fn(),
}))

const mockedRevalidateTag = vi.mocked(revalidateTag)
const mockedRevalidatePath = vi.mocked(revalidatePath)

describe('revalidateBarkpark', () => {
  const originalEnv = process.env.BARKPARK_ALLOW_ALL_REVALIDATE

  beforeEach(() => {
    mockedRevalidateTag.mockClear()
    mockedRevalidatePath.mockClear()
    delete process.env.BARKPARK_ALLOW_ALL_REVALIDATE
  })

  afterEach(() => {
    if (originalEnv === undefined) delete process.env.BARKPARK_ALLOW_ALL_REVALIDATE
    else process.env.BARKPARK_ALLOW_ALL_REVALIDATE = originalEnv
  })

  it('string input → revalidateTag called with barkpark:doc:<id>', () => {
    revalidateBarkpark('p1')
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(1)
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:doc:p1')
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('{_id, _type} → both tags revalidated', () => {
    revalidateBarkpark({ _id: 'p1', _type: 'post' })
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(2)
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:doc:p1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:type:post')
  })

  it('{ids: [a,b]} → two tag calls', () => {
    revalidateBarkpark({ ids: ['a', 'b'] })
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(2)
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:doc:a')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:doc:b')
  })

  it('{types: [t1,t2]} → two tag calls', () => {
    revalidateBarkpark({ types: ['t1', 't2'] })
    expect(mockedRevalidateTag).toHaveBeenCalledTimes(2)
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:type:t1')
    expect(mockedRevalidateTag).toHaveBeenCalledWith('barkpark:type:t2')
  })

  it("{path: '/'} WITHOUT env → throws", () => {
    expect(() => revalidateBarkpark({ path: '/' })).toThrow(
      'Path-based revalidation requires BARKPARK_ALLOW_ALL_REVALIDATE=1',
    )
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it("{path: '/'} WITH BARKPARK_ALLOW_ALL_REVALIDATE=1 → revalidatePath called", () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = '1'
    revalidateBarkpark({ path: '/' })
    expect(mockedRevalidatePath).toHaveBeenCalledTimes(1)
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/')
  })

  it("{paths: ['/a','/b']} WITH env → two path calls", () => {
    process.env.BARKPARK_ALLOW_ALL_REVALIDATE = 'true'
    revalidateBarkpark({ paths: ['/a', '/b'] })
    expect(mockedRevalidatePath).toHaveBeenCalledTimes(2)
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/a')
    expect(mockedRevalidatePath).toHaveBeenCalledWith('/b')
  })

  it('{} → no-op, no throw', () => {
    expect(() => revalidateBarkpark({})).not.toThrow()
    expect(mockedRevalidateTag).not.toHaveBeenCalled()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })

  it('no args → no-op, no throw', () => {
    expect(() => revalidateBarkpark()).not.toThrow()
    expect(mockedRevalidateTag).not.toHaveBeenCalled()
    expect(mockedRevalidatePath).not.toHaveBeenCalled()
  })
})
