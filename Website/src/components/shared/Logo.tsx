import Image from "next/image";

export default function Logo({ className = "" }: { className?: string }) {
  return (
    <Image
      src="/images/ghost.png"
      alt="GhostVM"
      width={32}
      height={36}
      className={className}
      priority
    />
  );
}
