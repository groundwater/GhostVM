"use client";

import { useTheme } from "next-themes";
import { useEffect, useState } from "react";
import Image from "next/image";

export default function Logo({ className = "" }: { className?: string }) {
  const { resolvedTheme } = useTheme();
  const [mounted, setMounted] = useState(false);

  useEffect(() => setMounted(true), []);

  if (!mounted) {
    return <div className={`h-8 w-32 ${className}`} />;
  }

  const src =
    resolvedTheme === "dark"
      ? "/images/ghostvm-logo-dark.png"
      : "/images/ghostvm-logo-light.png";

  return (
    <Image
      src={src}
      alt="GhostVM"
      width={128}
      height={32}
      className={className}
      priority
    />
  );
}
