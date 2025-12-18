import Foundation
import GhostVMKit

#if !arch(arm64)
print("vmctl requires Apple Silicon (arm64) to run macOS guests via Virtualization.framework.")
exit(1)
#endif

if #available(macOS 13.0, *) {
    CLI().run()
} else {
    print("vmctl requires macOS 13.0 or newer.")
    exit(1)
}
