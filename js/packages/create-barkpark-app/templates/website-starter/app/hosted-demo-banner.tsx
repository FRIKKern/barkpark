/**
 * Banner shown only on the hosted demo (barkpark.dev). Invisible on
 * self-hosted or local installs.
 */
export function HostedDemoBanner() {
  const apiUrl = process.env.BARKPARK_API_URL ?? ''
  if (!apiUrl.startsWith('https://barkpark.dev')) return null
  return (
    <div className="bg-amber-100 px-6 py-2 text-center text-sm text-amber-900">
      Connected to the Barkpark hosted demo. Data resets daily.
    </div>
  )
}
