import type { Metadata } from "next";
import Link from "next/link";
import Callout from "@/components/docs/Callout";
import CodeBlock from "@/components/docs/CodeBlock";

export const metadata: Metadata = {
  title: "How macOS Virtual Machines Actually Work on Apple Silicon - GhostVM",
};

export default function HowMacOSVMsWork() {
  return (
    <>
      <div className="not-prose mb-8">
        <Link
          href="/blog"
          className="text-sm text-ghost-600 dark:text-ghost-400 hover:underline"
        >
          &larr; Back to blog
        </Link>
      </div>

      <div className="flex items-center gap-3 text-sm text-gray-500 dark:text-gray-400 mb-2 not-prose">
        <time dateTime="2025-01-10">January 10, 2025</time>
        <span>&middot;</span>
        <span>7 min read</span>
      </div>

      <h1>How macOS Virtual Machines Actually Work on Apple Silicon</h1>
      <p className="lead">
        Apple Silicon VMs aren&apos;t emulation. They run native ARM code through
        the hypervisor with a full secure boot chain. Here&apos;s what happens
        under the hood.
      </p>

      <h2>Not Emulation — Native Execution</h2>
      <p>
        When you run a macOS VM on Apple Silicon, the guest operating system
        executes native ARM instructions directly on the CPU. There&apos;s no
        translation layer, no JIT compiler, no instruction-by-instruction
        interpretation. The Apple hypervisor carves out CPU time, memory, and
        device access for the guest, and the guest runs at near-native speed.
      </p>
      <p>
        This is fundamentally different from how tools like QEMU or older
        VirtualBox worked on Intel Macs when running non-x86 guests. On Apple
        Silicon, the host and guest share the same instruction set architecture,
        so the hypervisor&apos;s job is resource isolation, not translation.
      </p>

      <h2>The Boot Chain</h2>
      <p>
        Every macOS VM has its own secure boot chain, separate from the
        host&apos;s. Apple&apos;s Virtualization.framework manages this through
        several key objects:
      </p>

      <h3>VZMacOSBootLoader</h3>
      <p>
        This is the boot loader for macOS guests. Unlike Linux VMs (which use{" "}
        <code>VZLinuxBootLoader</code> with an explicit kernel and initrd), macOS
        VMs boot through Apple&apos;s own boot process. You don&apos;t supply a
        kernel — the framework handles the entire boot sequence.
      </p>

      <h3>Hardware Model</h3>
      <p>
        A <code>VZMacHardwareModel</code> describes the virtual hardware the
        guest sees. It&apos;s generated during installation from the restore
        image and encodes which virtual devices are available. This data is
        opaque — you serialize it to disk and hand it back to the framework on
        every boot.
      </p>

      <h3>Machine Identifier</h3>
      <p>
        A <code>VZMacMachineIdentifier</code> uniquely identifies a specific VM
        instance, much like a real Mac&apos;s serial number. It&apos;s generated
        once and must remain stable across boots. Changing it can make the guest
        think it&apos;s running on different hardware.
      </p>

      <h3>Auxiliary Storage</h3>
      <p>
        <code>VZMacAuxiliaryStorage</code> holds the guest&apos;s NVRAM/EFI
        variables — things like boot disk selection and startup security
        settings. This is the virtual equivalent of the EFI firmware storage on a
        physical Mac.
      </p>

      <h2>What a Restore Image Is</h2>
      <p>
        To install macOS in a VM, you need an IPSW (iPhone Software) restore
        image. Despite the name, this is the same format Apple uses for macOS on
        Apple Silicon. You can download it programmatically:
      </p>

      <CodeBlock language="swift" title="Fetching the latest restore image">
        {`VZMacOSRestoreImage.fetchLatestSupported { result in
    switch result {
    case .success(let image):
        // image.url is the download URL
        // image.buildVersion, image.operatingSystemVersion
        // image.mostFeaturefulSupportedConfiguration
    case .failure(let error):
        // Handle error
    }
}`}
      </CodeBlock>

      <p>
        The restore image contains the full macOS installer. The framework
        extracts the hardware model requirements from it, which is why you need
        the IPSW before you can create the VM configuration.
      </p>

      <h2>Installation via VZMacOSInstaller</h2>
      <p>
        Once you have a restore image and a configured VM,{" "}
        <code>VZMacOSInstaller</code> handles the actual installation. It boots
        the VM into a recovery-like environment, partitions the virtual disk, and
        installs macOS — just like restoring a physical Mac via Apple
        Configurator.
      </p>

      <CodeBlock language="swift" title="Installing macOS in a VM">
        {`let installer = VZMacOSInstaller(
    virtualMachine: vm,
    restoringFromImageAt: ipswURL
)
installer.install { result in
    // Installation complete
}`}
      </CodeBlock>

      <p>
        Installation takes a while (similar to installing macOS on a real Mac)
        and writes directly to the VM&apos;s virtual disk image.
      </p>

      <h2>What Lives Inside a VM Bundle</h2>
      <p>
        GhostVM stores each VM as a <code>.GhostVM</code> bundle — a directory
        that contains everything needed to run that specific VM:
      </p>

      <ul>
        <li>
          <code>disk.img</code> — The virtual disk (raw disk image)
        </li>
        <li>
          <code>hardwareModel.dat</code> — Serialized{" "}
          <code>VZMacHardwareModel</code>
        </li>
        <li>
          <code>machineIdentifier.dat</code> — Serialized{" "}
          <code>VZMacMachineIdentifier</code>
        </li>
        <li>
          <code>Auxiliary.efivars</code> — EFI variable storage
        </li>
        <li>
          <code>config.json</code> — VM settings (CPU count, memory, port
          forwards, shared folders)
        </li>
      </ul>

      <p>
        Because all state is self-contained in the bundle, you can move a VM to
        another Mac by copying the entire <code>.GhostVM</code> directory.
      </p>

      <Callout variant="info" title="Clone-friendly">
        Since the hardware model and machine identifier are stored as plain
        files, you can duplicate a VM bundle to create an instant clone — no
        reinstallation needed. GhostVM&apos;s clone feature does exactly this.
      </Callout>

      <h2>The Result: Near-Native Performance</h2>
      <p>
        The combination of native ARM execution, hardware-level memory isolation,
        and Apple&apos;s optimized virtio device drivers means macOS VMs on Apple
        Silicon perform remarkably well. In practice, most workloads run at
        90-95% of bare-metal speed. The main overhead is in I/O virtualization
        (disk and network), not CPU computation.
      </p>
      <p>
        This is what makes Apple Silicon VMs practical for real development
        work — they&apos;re fast enough that you can run Xcode, build projects,
        and run tests inside a VM without it feeling like a compromise.
      </p>

      <hr />

      <div className="not-prose mt-8">
        <Link
          href="/blog"
          className="text-sm text-ghost-600 dark:text-ghost-400 hover:underline"
        >
          &larr; Back to blog
        </Link>
      </div>
    </>
  );
}
