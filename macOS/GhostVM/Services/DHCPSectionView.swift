import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct DHCPSectionView: View {
    @Binding var dhcp: DHCPConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Enabled", isOn: $dhcp.enabled)
                .toggleStyle(.checkbox)
                .accessibilityIdentifier("dhcp.enabledToggle")

            if dhcp.enabled {
                HStack(spacing: 8) {
                    Text("Range:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80, alignment: .leading)
                    TextField("Start", text: $dhcp.rangeStart)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .accessibilityIdentifier("dhcp.rangeStartField")
                    Text("to")
                        .foregroundStyle(.secondary)
                    TextField("End", text: $dhcp.rangeEnd)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 140)
                        .accessibilityIdentifier("dhcp.rangeEndField")
                }

                HStack(spacing: 8) {
                    Text("Lease Time:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80, alignment: .leading)
                    TextField("Seconds", value: $dhcp.leaseTime, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .accessibilityIdentifier("dhcp.leaseTimeField")
                    Text("seconds")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

                HStack(spacing: 8) {
                    Text("Domain:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80, alignment: .leading)
                    TextField("e.g. vm.local", text: $dhcp.domainSuffix)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                        .accessibilityIdentifier("dhcp.domainSuffixField")
                }

                StaticLeaseListView(leases: $dhcp.staticLeases)
            }
        }
    }
}
