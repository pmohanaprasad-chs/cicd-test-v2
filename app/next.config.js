/** @type {import('next').NextConfig} */

const nextConfig = {
  output: 'standalone',
  reactStrictMode: true,
  // No basePath — middleware handles /dev and /staging rewrites
  // APP_ENV and BUILD_SHA are read at runtime via process.env in server components
};

module.exports = nextConfig;
