import fs from "fs";
import path from "path";

function readVersion(): string {
  const versionPath = path.resolve(process.cwd(), "../.version");
  try {
    return fs.readFileSync(versionPath, "utf-8").trim();
  } catch {
    return "unknown";
  }
}

export const siteConfig = {
  repo: "https://github.com/groundwater/GhostVM",
  version: readVersion(),
};
