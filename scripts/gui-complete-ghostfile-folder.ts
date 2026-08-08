import gui, { GuiKey, GuiKeyChord, GuiModifierKey } from "gui";
import { setTimeout as delay } from "node:timers/promises";

await gui.permissions.RequestPostInput();

const input = gui.input.Direct();
await input.Press(
  GuiKeyChord.WithModifiers(GuiKey.Character("a"), [GuiModifierKey.Command()]),
);
await input.PasteText("/Users/bender/Desktop/GhostVM/tmp/GhostFileShare");
await delay(300);
await input.PressKey(GuiKey.Named("return"));
await delay(800);
await input.PressKey(GuiKey.Named("return"));
await delay(800);
