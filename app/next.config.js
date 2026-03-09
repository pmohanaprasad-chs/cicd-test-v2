/** @type {import('next').NextConfig} */
const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,

  env: {
    NEXT_PUBLIC_APP_ENV: process.env.APP_ENV || 'local',
    NEXT_PUBLIC_BUILD_SHA: process.env.BUILD_SHA || 'dev',
  },
};

module.exports = nextConfig;
