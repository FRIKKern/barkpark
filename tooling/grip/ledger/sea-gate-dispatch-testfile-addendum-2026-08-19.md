# sibling-ETS-atomicity — dispatch verdicts for the REAL cloud limiter test files (addendum)

Companion to sea-gate-dispatch-matrix-2026-08-19.md. anchor origin/main d99cb95d0.

The brief's assumed path `cloud/test/barkpark_cloud/accounts/two_factor_rate_limiter_test.exs`
DOES NOT EXIST (`git cat-file -e origin/main:<p>` → absent). The real file is
`cloud/test/barkpark_cloud/two_factor_rate_limiter_test.exs` (no `accounts/` segment).
There is no dedicated device-auth limiter test file; its coverage sits in
`cloud/test/barkpark_cloud/device_auth_test.exs`.

Census: `git grep -l -E "TwoFactorRateLimiter|DeviceAuth.RateLimiter" origin/main -- cloud/test cloud/lib`

    for p in <files>; do
      printf '%s\n' "$p" | bash scripts/cloud-path-escape-check.sh   --match cloud
      printf '%s\n' "$p" | bash scripts/console-path-escape-check.sh --match console
    done

| baseline test file | cloud | console |
|---|---|---|
| cloud/test/barkpark_cloud/two_factor_rate_limiter_test.exs | true | false |
| cloud/test/barkpark_cloud/device_auth_test.exs | true | false |
| cloud/test/barkpark_cloud/push/device_token_rate_limit_test.exs | true | false |
| cloud/test/barkpark_cloud/web/router_register_rate_bucket_test.exs | true | **true** |
| cloud/test/barkpark_cloud/web/router_signin_rate_bucket_test.exs | true | **true** |
| cloud/test/barkpark_cloud/web/router_two_factor_test.exs | true | **true** |
| cloud/test/barkpark_cloud/web/router_oauth_two_factor_test.exs | true | **true** |
| cloud/test/web/auth_onboarding_error_test.exs | true | false |

CONSEQUENCE FOR THE BUILDER: `cloud/test/barkpark_cloud/web/**` is a CONSOLE_PATHS
entry in its own right. Four of the eight baseline files sit inside it, so touching
any of them fires the three Chrome jobs even without a `cloud/lib` edit. Put NEW twin
harnesses at `cloud/test/barkpark_cloud/<module>_concurrency_test.exs` (outside `web/`)
— but note this saves nothing once the `cloud/lib` fix is in the same PR, since
`cloud/lib/**` already forces console=true.
