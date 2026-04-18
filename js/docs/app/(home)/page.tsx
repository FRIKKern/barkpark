import Link from 'next/link';

export default function HomePage() {
  return (
    <main
      style={{
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        textAlign: 'center',
        justifyContent: 'center',
        padding: '2rem',
      }}
    >
      <h1 style={{ fontSize: '2rem', fontWeight: 'bold', marginBottom: '1rem' }}>
        Barkpark docs
      </h1>
      <p>
        Start at{' '}
        <Link
          href="/docs/getting-started"
          style={{ fontWeight: 600, textDecoration: 'underline' }}
        >
          /docs/getting-started
        </Link>
        .
      </p>
    </main>
  );
}
