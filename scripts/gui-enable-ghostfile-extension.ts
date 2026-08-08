import gui from "gui";

await gui.permissions.RequestPostInput();
await gui.permissions.RequestViewHierarchyAccess();

const app = gui.applications.Named("System Settings");
await app.Focus();
const window = (await app.Windows().All())[0];
if (!window) throw new Error("System Settings window not found");
let root = await window.RootNode();
const switches = await root.FindAll(async (node) => await node.Role() === "AXCheckBox");
let moduleSwitch = null;
for (const candidate of switches.All()) {
  const frame = await candidate.Frame();
  if (frame && frame.origin.x > 1300 && frame.origin.y > 330 && frame.origin.y < 430) {
    moduleSwitch = candidate;
    break;
  }
}
if (!moduleSwitch) throw new Error("FSKit Modules switch not found");
await moduleSwitch.Press();

root = await window.RootNode();
const done = await root.Find(async (node) =>
  await node.Role() === "AXButton" && await node.AccessibleName() === "Done"
);
if (!done) throw new Error("Done button not found");
await done.Press();
