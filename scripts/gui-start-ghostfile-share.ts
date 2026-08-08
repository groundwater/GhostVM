import gui, { GuiKey, GuiKeyChord, GuiModifierKey, GuiPoint, GuiWaitTimeout } from "gui";
import { setTimeout as delay } from "node:timers/promises";

const sharePath = "/Users/bender/Desktop/GhostVM/tmp/GhostFileShare";
const accessKey = "ghostfile-test-key";

await gui.permissions.RequestPostInput();
await gui.permissions.RequestViewHierarchyAccess();

const app = gui.applications.Named("GhostFile");
await app.Focus();
const input = gui.input.Direct();
let windows = await app.Windows().All();
let window: (typeof windows)[number] | null = null;
for (const candidate of windows) {
  if (await candidate.Title() === "GhostFile") window = candidate;
}
if (!window) throw new Error("GhostFile window not found");

let initialRoot = await window.RootNode();
const selectedFolder = await initialRoot.Find(
  async (node) => await node.AccessibleName() === sharePath,
);
if (!selectedFolder) {
  let dialog: (typeof windows)[number] | null = null;
  for (const candidate of windows) {
    if (await candidate.Title() === "Choose a folder to share") dialog = candidate;
  }
  if (dialog) {
    await dialog.Raise();
    await delay(200);
    let goToRoot = await dialog.RootNode();
    let goToFields = await goToRoot.FindAll(async (node) => await node.Role() === "AXTextField");
    let goToField = null;
    for (const field of goToFields.All()) {
      const frame = await field.Frame();
      if (frame && frame.size.width > 300 && frame.origin.y > 220 && frame.origin.y < 320) {
        goToField = field;
        break;
      }
    }
    if (!goToField) {
      await input.Press(
        GuiKeyChord.WithModifiers(GuiKey.Character("g"), [GuiModifierKey.Command(), GuiModifierKey.Shift()]),
      );
      await delay(300);
      goToRoot = await dialog.RootNode();
      goToFields = await goToRoot.FindAll(async (node) => await node.Role() === "AXTextField");
      for (const field of goToFields.All()) {
        const frame = await field.Frame();
        if (frame && frame.size.width > 300 && frame.origin.y > 220 && frame.origin.y < 320) {
          goToField = field;
          break;
        }
      }
    }
    if (!goToField) throw new Error("Go to folder field not found");
    await goToField.Focus();
    await input.Press(
      GuiKeyChord.WithModifiers(GuiKey.Character("a"), [GuiModifierKey.Command()]),
    );
    await input.PasteText(sharePath);
    await input.PressKey(GuiKey.Named("return"));
    await delay(800);
    const dialogRoot = await dialog.RootNode();
    const confirm = await dialogRoot.Find(async (node) => await node.AccessibleName() === "Share Folder");
    if (!confirm) throw new Error("Share Folder button not found");
    await input.ClickNode(confirm);
    await delay(800);
  } else {
  const choose = await initialRoot.Find(async (node) => await node.AccessibleName() === "Choose…");
  if (!choose) throw new Error("Choose button not found");
  await input.ClickNode(choose);
  await input.Press(
    GuiKeyChord.WithModifiers(GuiKey.Character("g"), [GuiModifierKey.Command(), GuiModifierKey.Shift()]),
  );
  await input.PasteText(sharePath);
  await input.PressKey(GuiKey.Named("return"));
  await delay(500);
  await input.PressKey(GuiKey.Named("return"));
  await delay(500);
  }
}

let root = await window.RootNode();
const fields = await root.FindAll(async (node) => await node.Role() === "AXTextField");
if (fields.Count() < 3) throw new Error(`Expected three text fields, found ${fields.Count()}`);
async function replaceFocusedText(value: string) {
  await input.Press(
    GuiKeyChord.WithModifiers(GuiKey.Character("a"), [GuiModifierKey.Command()]),
  );
  await input.PasteText(value);
}
await fields.At(0)!.Focus();
await replaceFocusedText("GhostFileQUIC");
await fields.At(1)!.Focus();
await replaceFocusedText("0");
await fields.At(2)!.Focus();
await replaceFocusedText(accessKey);

const start = await root.Find(async (node) => await node.AccessibleName() === "Start Sharing");
if (!start) throw new Error("Start Sharing button not found");
await start.WaitUntilActionable(GuiWaitTimeout.Seconds(5));
const startFrame = await start.Frame();
if (!startFrame) throw new Error("Start Sharing button has no frame");
await input.Click(
  GuiPoint.At(
    startFrame.origin.x + startFrame.size.width / 2,
    startFrame.origin.y + startFrame.size.height / 2,
  ),
);

root = await window.RootNode();
const lines: string[] = [];
const nodes = await root.SelfAndDescendants();
for (const node of nodes.All()) {
  const name = await node.AccessibleName();
  const value = await node.Value();
  if (name || value) lines.push(`${await node.Role()} ${JSON.stringify(name)} ${JSON.stringify(value)}`);
}
await gui.pasteboard.SetText(lines.join("\n"));
