import SwiftUI
import GhostVMKit

@available(macOS 13.0, *)
struct RouterDetailView: View {
    @Binding var router: RouterConfig
    var vmNames: [String] = []

    private enum Tab: String, CaseIterable {
        case wan = "WAN"
        case lan = "LAN"
        case dhcp = "DHCP"
        case dns = "DNS"
        case firewall = "Firewall"
        case portForward = "NAT"
        case routes = "Routes"
        case aliases = "Aliases"
    }

    @State private var selectedTab: Tab = .wan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Name + summary
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text("Name:")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 80, alignment: .leading)
                    TextField("Network name", text: $router.name)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("router.nameField")
                }

                Text(router.summaryLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)

            // Tabs
            Picker("", selection: $selectedTab) {
                ForEach(Tab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)

            Divider()
                .padding(.top, 8)

            // Tab content
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch selectedTab {
                    case .wan:
                        WANSectionView(wan: $router.wan)
                            .accessibilityIdentifier("router.wanSection")
                    case .lan:
                        lanSection
                            .accessibilityIdentifier("router.lanSection")
                    case .dhcp:
                        DHCPSectionView(dhcp: $router.dhcp)
                            .accessibilityIdentifier("router.dhcpSection")
                    case .dns:
                        DNSSectionView(dns: $router.dns)
                            .accessibilityIdentifier("router.dnsSection")
                    case .firewall:
                        firewallSection
                            .accessibilityIdentifier("router.firewallSection")
                    case .portForward:
                        RouterNATListView(rules: $router.portForwarding)
                            .accessibilityIdentifier("router.natSection")
                    case .routes:
                        StaticRouteListView(routes: $router.staticRoutes)
                            .accessibilityIdentifier("router.routesSection")
                    case .aliases:
                        AliasListView(aliases: $router.aliases)
                            .accessibilityIdentifier("router.aliasesSection")
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !vmNames.isEmpty {
                Divider()
                HStack(spacing: 4) {
                    Text("VMs using this network:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(vmNames.joined(separator: ", "))
                        .font(.caption)
                }
                .padding(12)
            }
        }
    }

    // MARK: - LAN Section

    @ViewBuilder
    private var lanSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Text("Subnet:")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                TextField("e.g. 10.100.0.0/24", text: $router.lan.subnet)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("lan.subnetField")
            }

            HStack(spacing: 12) {
                Text("Gateway:")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 80, alignment: .leading)
                TextField("e.g. 10.100.0.1", text: $router.lan.gateway)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("lan.gatewayField")
            }
        }
    }

    // MARK: - Firewall Section

    @ViewBuilder
    private var firewallSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Default Policy:", selection: $router.firewall.defaultPolicy) {
                Text("Allow").tag(FirewallDefaultPolicy.allow)
                Text("Block").tag(FirewallDefaultPolicy.block)
            }
            .pickerStyle(.radioGroup)
            .horizontalRadioGroupLayout()
            .accessibilityIdentifier("firewall.defaultPolicyPicker")

            NetworkRuleListView(rules: $router.firewall.rules)
        }
    }
}
