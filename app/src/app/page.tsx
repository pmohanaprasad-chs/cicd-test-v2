import type { Metadata } from 'next';

export const metadata: Metadata = {
  title: 'CI/CD Demo',
  description: 'Enterprise CI/CD reference implementation',
};

export default function HomePage() {
  const appEnv = process.env.APP_ENV ?? 'local';
  const buildSha = process.env.BUILD_SHA ?? 'unknown';

  return (
    <main
      style={{
        minHeight: '100vh',
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        fontFamily: 'system-ui, sans-serif',
        background: '#0f172a',
        color: '#f8fafc',
        gap: '1rem',
      }}
    >
      <h1 data-testid="headline" style={{ fontSize: '2.5rem', margin: 0 }}>
        Hello from CI/CD
      </h1>
      <p style={{ color: '#94a3b8', margin: 0 }}>
        Environment:{' '}
        <strong data-testid="env-badge" style={{ color: '#38bdf8' }}>
          {appEnv}
        </strong>
      </p>
      <p style={{ color: '#64748b', fontSize: '0.875rem', margin: 0 }}>
        Build: <code>{buildSha}</code>
      </p>
    </main>
  );
}
