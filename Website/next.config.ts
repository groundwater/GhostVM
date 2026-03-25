import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  ...(process.env.NODE_ENV === "production" && { output: "export" }),
  images: {
    unoptimized: true,
  },
  devIndicators: false,
};

export default nextConfig;
