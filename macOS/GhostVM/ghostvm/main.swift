import Foundation
import GhostVMKit

#if !arch(arm64)
print("ghostvm requires Apple Silicon (arm64) to run macOS guests via Virtualization.framework.")
exit(1)
#endif

if #available(macOS 13.0, *) {
    CLI().run()
} else {
    print("ghostvm requires macOS 13.0 or newer.")
    exit(1)
}
