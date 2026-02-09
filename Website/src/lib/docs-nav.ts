export interface NavItem {
  title: string;
  href: string;
  children?: NavItem[];
}

export const docsNav: NavItem[] = [
  { title: "Getting Started", href: "/docs/getting-started" },
  { title: "GUI App", href: "/docs/gui-app" },
  {
    title: "Creating VMs",
    href: "/docs/creating-vms",
    children: [
      { title: "macOS", href: "/docs/creating-vms/macos" },
    ],
  },
  { title: "CLI Reference", href: "/docs/cli" },
  { title: "VM Bundles", href: "/docs/vm-bundles" },
  { title: "Snapshots", href: "/docs/snapshots" },
  {
    title: "Services",
    href: "/docs/services",
    children: [
      { title: "Clipboard Sync", href: "/docs/services/clipboard-sync" },
      { title: "File Transfer", href: "/docs/services/file-transfer" },
      { title: "Port Forwarding", href: "/docs/services/port-forwarding" },
      { title: "Shared Folders", href: "/docs/services/shared-folders" },
    ],
  },
  { title: "GhostTools", href: "/docs/ghosttools" },
  { title: "Architecture", href: "/docs/architecture" },
];

export function flattenNav(items: NavItem[]): NavItem[] {
  const result: NavItem[] = [];
  for (const item of items) {
    result.push(item);
    if (item.children) {
      result.push(...item.children);
    }
  }
  return result;
}

export function getPrevNext(currentHref: string) {
  const flat = flattenNav(docsNav);
  const idx = flat.findIndex((item) => item.href === currentHref);
  return {
    prev: idx > 0 ? flat[idx - 1] : null,
    next: idx < flat.length - 1 ? flat[idx + 1] : null,
  };
}
