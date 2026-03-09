import { NextResponse } from 'next/server';
import type { NextRequest } from 'next/server';

// Rewrite /dev/* and /staging/* to /* internally
// The ALB routes these paths to the correct container,
// but Next.js only knows routes at / — so we strip the prefix.
export function middleware(request: NextRequest) {
  const pathname = request.nextUrl.pathname;

  // Strip /dev or /staging prefix and rewrite internally
  if (pathname.startsWith('/dev/') || pathname === '/dev') {
    const newPath = pathname.replace(/^\/dev/, '') || '/';
    return NextResponse.rewrite(new URL(newPath, request.url));
  }

  if (pathname.startsWith('/staging/') || pathname === '/staging') {
    const newPath = pathname.replace(/^\/staging/, '') || '/';
    return NextResponse.rewrite(new URL(newPath, request.url));
  }

  return NextResponse.next();
}

export const config = {
  // Run middleware on /dev and /staging paths only
  matcher: ['/dev', '/dev/:path*', '/staging', '/staging/:path*'],
};
