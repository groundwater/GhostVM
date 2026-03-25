import sharp from "sharp";
import { readdir, stat, writeFile } from "node:fs/promises";
import { join, dirname, extname, basename } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PUBLIC_IMAGES = join(__dirname, "..", "public", "images");
const MAX_WIDTH = 2000;
const PHOTO_QUALITY = 80;
const ICON_QUALITY = 85;

// Icons and small UI assets get higher quality
const ICON_DIRS = new Set(["dock-icons", "vm-icons", "wallpapers"]);

async function* walk(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const full = join(dir.toString(), entry.name);
    if (entry.isDirectory()) yield* walk(full);
    else yield full;
  }
}

async function optimize() {
  let converted = 0;
  let skipped = 0;
  let totalSaved = 0;

  for await (const file of walk(PUBLIC_IMAGES)) {
    const ext = extname(file).toLowerCase();
    if (ext !== ".png" && ext !== ".jpg" && ext !== ".jpeg") continue;

    const webpPath = file.replace(/\.(png|jpe?g)$/i, ".webp");
    const srcStat = await stat(file);

    // Skip if webp exists and is newer than source
    try {
      const dstStat = await stat(webpPath);
      if (dstStat.mtimeMs >= srcStat.mtimeMs) {
        skipped++;
        continue;
      }
    } catch {
      // webp doesn't exist yet — convert
    }

    // Determine quality based on directory
    const parentDir = basename(join(file, ".."));
    const quality = ICON_DIRS.has(parentDir) ? ICON_QUALITY : PHOTO_QUALITY;

    let pipeline = sharp(file);
    const metadata = await pipeline.metadata();

    // Resize large screenshots
    if (metadata.width && metadata.width > MAX_WIDTH) {
      pipeline = pipeline.resize({ width: MAX_WIDTH, withoutEnlargement: true });
    }

    const webpBuf = await pipeline.webp({ quality }).toBuffer();
    await writeFile(webpPath, webpBuf);

    const saved = srcStat.size - webpBuf.length;
    totalSaved += saved;
    converted++;

    const pct = ((saved / srcStat.size) * 100).toFixed(0);
    const srcKB = (srcStat.size / 1024).toFixed(0);
    const dstKB = (webpBuf.length / 1024).toFixed(0);
    console.log(
      `  ${file.replace(PUBLIC_IMAGES + "/", "")}  ${srcKB} KB → ${dstKB} KB  (−${pct}%)`
    );
  }

  console.log();
  console.log(
    `Done. ${converted} converted, ${skipped} skipped, ${(totalSaved / 1024 / 1024).toFixed(1)} MB saved.`
  );
}

optimize().catch((err) => {
  console.error(err);
  process.exit(1);
});
