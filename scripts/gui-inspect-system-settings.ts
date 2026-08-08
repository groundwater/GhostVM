import gui from "gui";

await gui.permissions.RequestViewHierarchyAccess();

const app = gui.applications.Named("System Settings");
const windows = await app.Windows().All();
const lines = [`windows=${windows.length}`];
for (let windowIndex = 0; windowIndex < windows.length; windowIndex += 1) {
  const window = windows[windowIndex];
  lines.push(`window[${windowIndex}] title=${await window.Title()}`);
  const nodes = await (await window.RootNode()).SelfAndDescendants();
  for (let nodeIndex = 0; nodeIndex < nodes.Count(); nodeIndex += 1) {
    const node = nodes.At(nodeIndex)!;
    const role = await node.Role();
    const name = await node.AccessibleName();
    const value = await node.Value();
    if (name || value || role === "AXCheckBox") {
      lines.push(`  ${nodeIndex}: role=${role} name=${JSON.stringify(name)} value=${JSON.stringify(value)} frame=${JSON.stringify(await node.Frame())}`);
    }
  }
}
await gui.pasteboard.SetText(lines.join("\n"));
