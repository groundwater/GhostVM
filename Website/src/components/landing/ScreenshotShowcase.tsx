import { DesktopFrame, WindowScreenshot } from "./DesktopFrame";

export default function ScreenshotShowcase() {
  return (
    <section className="py-20 bg-gray-50 dark:bg-gray-900/50">
      <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8">
        <h2 className="text-3xl font-bold text-center mb-4">
          Run multiple workspaces, each fully isolated
        </h2>
        <p className="text-center text-gray-600 dark:text-gray-400 mb-10 max-w-xl mx-auto">
          Every VM is a self-contained workspace — its own OS, tools, and
          files. Run as many as you need in parallel, each isolated from the
          others and from your host.
        </p>
        <div className="grid grid-cols-1 md:grid-cols-2 gap-8 max-w-5xl mx-auto">
          <div>
            <DesktopFrame>
              <WindowScreenshot
                src="/images/screenshots/vm-list-with-vms.png"
                alt="GhostVM main window showing a list of virtual machines"
              />
            </DesktopFrame>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-3 text-center">
              Multiple workspaces running side by side.
            </p>
          </div>
          <div>
            <DesktopFrame>
              <WindowScreenshot
                src="/images/screenshots/create-vm-sheet.png"
                alt="GhostVM Create VM dialog"
              />
            </DesktopFrame>
            <p className="text-sm text-gray-600 dark:text-gray-400 mt-3 text-center">
              Spin up a new workspace in seconds.
            </p>
          </div>
        </div>
      </div>
    </section>
  );
}
