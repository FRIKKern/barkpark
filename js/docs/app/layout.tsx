import { RootProvider } from 'fumadocs-ui/provider';
import 'fumadocs-ui/style.css';
import type { ReactNode } from 'react';

export default function Layout({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <body
        style={{
          display: 'flex',
          flexDirection: 'column',
          minHeight: '100vh',
          fontFamily:
            'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
        }}
      >
        <RootProvider>{children}</RootProvider>
      </body>
    </html>
  );
}
