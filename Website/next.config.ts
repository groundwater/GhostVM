import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  output: "export",
  basePath: "/GhostVM",
  images: {
    unoptimized: true,
  },
};

export default nextConfig;
