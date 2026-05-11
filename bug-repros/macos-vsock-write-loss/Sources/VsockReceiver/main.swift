// VsockReceiver — runs on the macOS host.
//
// Attaches to a *running* GhostVM-style VM bundle via Virtualization.framework,
// opens a vsock connection to the given port (where VsockSender is listening
// inside the guest), and reads N bytes. Reports how many bytes actually arrived.
//
// To keep this self-contained, the receiver expects you to point it at a
// bundle directory containing a VZVirtualMachineConfiguration-compatible setup.
// In practice the easiest path: run this against the same VM you use for
// GhostVM development — the bundle path is what GhostVM passes via `--vm-bundle`.
//
// However: this binary is **not** a full VM lifecycle manager. It expects an
// already-running VM that exposes vsock. For the simplest repro we just open
// a vsock connection to the guest's vsock port assuming the VM is up.
//
// Usage (on the host):
//   VsockReceiver <vm-bundle-path> <port> <expected-bytes>
//
// The `vm-bundle-path` is used purely to discover the VZVirtualMachine; the
// repro intentionally avoids creating/starting a VM so it works against any
// already-running guest.
//
// NOTE: macOS does not expose AF_VSOCK directly for host→guest; the host
// must go through VZVirtioSocketDevice. This is why the host side looks
// asymmetric vs the guest side.

import Darwin
import Foundation
import Virtualization

let args = CommandLine.arguments
guard args.count == 4,
      let port = UInt32(args[2]),
      let expectedBytes = Int(args[3]),
      expectedBytes > 0 else {
    FileHandle.standardError.write(Data("Usage: \(args[0]) <vm-bundle> <port> <expected-bytes>\n".utf8))
    exit(2)
}

let vmBundlePath = args[1]

// To keep the repro minimal, we don't actually load the VM configuration —
// that's a lot of plumbing. Instead, we ask the user to ALREADY be running
// the VM (via GhostVM, vmctl, or `make run`) and we connect to its known
// vsock fd from a child process they've launched manually with the VM
// reference.
//
// The cleanest way to run this in practice is: copy this receiver's logic
// into a `vmctl` subcommand and run it as `vmctl repro-recv <port> <bytes>`,
// or run it as a child of the GhostVM app where you already have a
// VZVirtualMachine instance handy.
//
// For now, this binary fails loud and tells you to invoke it the right way.
// Once you've added the equivalent of this read loop inside vmctl (or any
// program that has a VZVirtualMachine handle), you have your repro.

print("""
    VsockReceiver: this binary is a template — it can't open a vsock
    connection to a VM without first loading the VM via Virtualization.framework,
    which requires the same entitlements and configuration GhostVM uses.

    To run the receive side of the repro, either:
      (a) Use GhostVM itself with a TEST connectRaw() call to port \(port),
          then run the read loop below against the returned fd.
      (b) Add a `vmctl repro-recv \(port) \(expectedBytes)` subcommand that
          uses the existing GhostVM connectRaw() helper, then drops into
          the loop below.

    The actual read loop (paste into wherever you have an fd):

        var buffer = [UInt8](repeating: 0, count: 65536)
        var totalRead = 0
        var readCalls = 0
        var lastLog = Date()
        let started = Date()
        while totalRead < \(expectedBytes) {
            let n = Darwin.read(fd, &buffer, buffer.count)
            readCalls += 1
            if n > 0 {
                totalRead += n
                if Date().timeIntervalSince(lastLog) > 1.0 {
                    print("  …received \\(Double(totalRead)/1_048_576) MiB (\\(totalRead)/\\(\(expectedBytes)))")
                    lastLog = Date()
                }
            } else if n == 0 {
                print("  !! EOF after \\(totalRead)/\\(\(expectedBytes)) bytes (short by \\(\(expectedBytes) - totalRead))")
                break
            } else if errno == EINTR {
                continue
            } else {
                print("  !! read errno=\\(errno) after \\(totalRead) bytes")
                break
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        print(\"\"\"
        VsockReceiver: FINISHED reading
          expected:      \\(\(expectedBytes)) bytes
          actually got:  \\(totalRead) bytes
          missing:       \\(\(expectedBytes) - totalRead) bytes
          time:          \\(String(format: \"%.2f\", elapsed)) s
          read() calls:  \\(readCalls)
        \"\"\")

    Bundle path you passed: \(vmBundlePath)
    """)

// Used so we don't take unused-arg warnings
_ = vmBundlePath
exit(0)
