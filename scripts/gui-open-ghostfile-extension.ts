import gui, { GuiPoint, GuiScrollDelta } from "gui";

await gui.permissions.RequestPostInput();
await gui.permissions.RequestViewHierarchyAccess();

const app = gui.applications.Named("System Settings");
await app.Focus();
const input = gui.input.Direct();
let window = (await app.Windows().All())[0];
if (!window) throw new Error("System Settings window not found");

await input.Scroll(GuiPoint.At(1400, 900), GuiScrollDelta.Pixels(0, -420));
let root = await window.RootNode();
const ghostFile = await root.Find(async (node) =>
  await node.Role() === "AXStaticText" && await node.AccessibleName() === "GhostFile"
);
if (!ghostFile) throw new Error("GhostFile extension row not found");
await ghostFile.Focus();
root = await window.RootNode();
const visibleGhostFile = await root.Find(async (node) =>
  await node.Role() === "AXStaticText" && await node.AccessibleName() === "GhostFile"
);
if (!visibleGhostFile) throw new Error("GhostFile extension row disappeared");
const ghostFrame = await visibleGhostFile.Frame();
if (!ghostFrame) throw new Error("GhostFile row has no frame");

const detailButtons = await root.FindAll(async (node) =>
  await node.Role() === "AXButton" && await node.AccessibleName() === "Show Detail"
);
let detail = null;
for (const button of detailButtons.All()) {
  const frame = await button.Frame();
  if (frame && Math.abs(frame.origin.y - ghostFrame.origin.y) < 8) {
    detail = button;
    break;
  }
}
if (!detail) throw new Error("GhostFile Show Detail button not found");
await input.ClickNode(detail);
