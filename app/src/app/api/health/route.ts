import { NextResponse } from "next/server";

export const dynamic = "force-static";

export async function GET() {
  return NextResponse.json(
    {
      status: "ok",
      message: "Hello from CI/CD",
      env: process.env.APP_ENV ?? "local",
      sha: process.env.BUILD_SHA ?? "dev",
      timestamp: new Date().toISOString(),
    },
    { status: 200 }
  );
}
