export default function ghostVMLoader({
  src,
}: {
  src: string;
  width: number;
  quality?: number;
}) {
  // In static export with basePath, unoptimized images don't get the prefix.
  // This loader ensures all images are served from the correct subdirectory.
  const basePath = "/ghostvm";
  if (src.startsWith("/") && !src.startsWith(basePath)) {
    return `${basePath}${src}`;
  }
  return src;
}
