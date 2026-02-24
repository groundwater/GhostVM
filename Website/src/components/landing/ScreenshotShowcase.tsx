import Image from "next/image";
import { DesktopFrame, WindowScreenshot } from "./DesktopFrame";

export default function ScreenshotShowcase() {
  return (
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <h2 className="text-3xl font-bold text-center mb-4">
          Run multiple workspaces, each fully isolated
        </h2>
        <p className="text-center text-gray-600 dark:text-gray-400 mb-10 max-w-xl mx-auto">
          Each workspace is its own macOS. Run as many as you need, fully
          isolated from each other and your host.
        </p>
        <div className="max-w-3xl mx-auto">
          <div className="rounded-xl overflow-hidden border border-gray-200 dark:border-gray-700 shadow-xl">
            <Image
              src="/images/screenshots/multiple-vms.webp"
              alt="Two workspace windows running side by side on the macOS desktop"
              width={2992}
              height={1934}
              className="w-full h-auto block"
            />
          </div>
          <p className="text-sm text-gray-600 dark:text-gray-400 mt-3 text-center">
            Each workspace runs as its own window.
          </p>
        </div>
      </div>
    </section>
  );
}
