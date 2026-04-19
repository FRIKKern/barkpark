/** @type {import('next').NextConfig} */
const nextConfig = {
  images: {
    remotePatterns: [
      {
        protocol: "http",
        hostname: "89.167.28.206",
      },
      {
        protocol: "https",
        hostname: "api.barkpark.cloud",
      },
    ],
  },
};

export default nextConfig;
