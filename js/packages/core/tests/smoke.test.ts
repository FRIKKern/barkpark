import { describe, it, expect } from 'vitest'
import * as mod from '../src/index'

describe('@barkpark/core scaffold', () => {
  it('exports createClient', () => {
    expect(typeof mod.createClient).toBe('function')
  })
  it('exports error classes', () => {
    expect(new mod.BarkparkNetworkError('x')).toBeInstanceOf(Error)
    expect(new mod.BarkparkSchemaMismatchError('x').name).toBe('BarkparkSchemaMismatchError')
    expect(new mod.BarkparkAuthError('x').code).toBe('BarkparkAuthError')
  })
  it('typedClient is runtime-identity', () => {
    const c = { a: 1 } as unknown as mod.BarkparkClient
    expect(mod.typedClient(c)).toBe(c)
  })

  it('typedClient narrows doc/docs by the TypeMap (type-level)', () => {
    interface Post {
      _id: string
      title: string
    }
    type TMap = { post: Post }

    // Compile-time assertions only — this fn is type-checked but NEVER executed
    // (bp.doc would be undefined on a dummy client). The value is the types.
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    function _typeAssertions(bp: mod.TypedClient<TMap>) {
      // positive: a known type resolves to its concrete interface
      const p: Promise<Post | null> = bp.doc('post', 'x')
      void p
      // negative: an unknown type is a compile error
      // @ts-expect-error 'nope' is not a key of the TypeMap
      void bp.doc('nope', 'x')

      // getDocuments is type-keyed too — it narrows by the TypeMap (revert the
      // TypedClient override and BarkparkDocument[] won't assign to Post[]).
      const many: Promise<Array<Post | null>> = bp.getDocuments('post', ['x', 'y'])
      void many
      // @ts-expect-error 'nope' is not a key of the TypeMap
      void bp.getDocuments('nope', ['x'])
    }

    // runtime is the identity
    const c = { a: 1 } as unknown as mod.BarkparkClient
    expect(mod.typedClient<TMap>(c)).toBe(c)
  })

  it('exports the query-response envelope type (QueryEnvelope, the current sibling of ReadEnvelope)', () => {
    // Compile-time guard: a missing re-export fails to typecheck here. Used in
    // type position only — no runtime value needed.
    type _Envelopes = mod.QueryEnvelope | mod.ReadEnvelope | mod.QueryPage<unknown>
    const _e: _Envelopes | undefined = undefined
    expect(_e).toBeUndefined()
  })

  it('exports the media option/result types used in public method signatures', () => {
    // listAssets(): Promise<MediaAssetPage> and getAsset/deleteAsset/…(opts?:
    // AssetOptions) are public, so a consumer must be able to NAME these types
    // (e.g. to type a wrapper fn or a variable holding the result). Compile-time
    // guard: dropping any re-export from index.ts fails to typecheck here.
    type _MediaTypes = mod.MediaAssetPage | mod.AssetOptions | mod.ListAssetsOptions
    const _m: _MediaTypes | undefined = undefined
    expect(_m).toBeUndefined()
  })
})
