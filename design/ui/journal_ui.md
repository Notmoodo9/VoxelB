# The adventurer's journal UI (milestone 18, part 5)

Interviewed 2026-10-13 after the owner's feedback on v0.18.4: the UI looked
clean but "like a hacked client" — glassy dark panels and teal accents that
don't belong to the world. **Status: approved 2026-10-13.**

## Summary

Every screen becomes part of an **adventurer's leather-bound journal**: an
open book with a stitched dark red-brown leather cover around warm cream
parchment pages, dark sepia ink, brass corners. Slots are inked boxes drawn
on the page. The inventory is the right page; crafting, the recipe book or
the Creative catalog the left page. The main menu, settings, world list and
pause menu use the same pages; the HUD hotbar becomes a leather strip.
The smooth font stays. Gameplay additions: an **off hand**, a **toggleable
recipe book**, and **Shift+drag** to split a stack evenly.

## Decisions

| Topic | Decision |
|---|---|
| Look | Leather-bound book: stitched dark leather cover, cream parchment pages (left + right), brass corner pieces; no blur, no glass |
| Palette | Warm cream pages, dark sepia-brown ink for lines and text, deep red-brown leather, brass accents; items stay vibrant on the light pages |
| Slots | Inked boxes with a soft shadow, as if drawn on the page; the slot in hand / hovered slot gets a darker ink frame |
| Font | Keep the current smooth font (ink-coloured on pages, light on leather) |
| Scope | Everything: inventory, crafting, chests, furnaces, tooltips, HUD (hotbar as a leather strip with parchment slots), main menu, pause menu, settings, world list, credits |
| Buttons | Hand-inked frames on the page that darken on hover; important ones (Play, Create, Resume) get a red wax-seal mark. Sliders: an ink line with a brass knob. Toggles: a small inked checkbox. Text fields: an inked writing line |
| Tooltips | A small parchment slip with an ink border |
| Recipe book | Toggled by a small book icon next to the crafting grid and a rebindable key (default R); it is the left page; it stays open or closed the way you last left it; a toggle inside it switches "what I can make" / "show all" |
| Creative | The catalog is the left page: tabs as ribbon bookmarks along the page's top edge, search as an inked writing line; the inventory stays on the right page |
| Dragging | Hold a stack, hold **Shift** and drag over slots: the stack is split evenly among them (leftover stays on the cursor). **Right-drag** puts one item in each slot. Shift-click still moves stacks between inventory and container |
| Off hand | A slot for any item; **F** swaps it with the main hand (rebindable). Light items (torches, glowing blocks) light the area from the off hand; blocks are placed from the off hand when the main hand holds a tool or nothing placeable; shields, maps etc. use it later |
| Off hand UI | A separate slot just left of the hotbar on the HUD and next to the inventory in the book; in first person the item is held lower-left, mirroring the main hand |

## Building plan

1. **Journal art:** leather, parchment, stitching, brass corner, ink slot,
   wax seal, bookmark ribbon and book-icon textures (pixel art made by a
   generator script like the block textures, but at a higher resolution
   for the UI), and a UI renderer path for 9-slice textured panels.
2. **In-game screens** in the book: inventory, crafting + recipe book
   toggle, chests, furnaces, Creative catalog, tooltips, HUD hotbar strip.
3. **Off hand** (slot, F swap, HUD slot, first-person left hand, light and
   placing from it, saved in player.dat) and **Shift+drag / right-drag**.
4. **Menus** (main, pause, settings, world list, create, credits) as
   journal pages with inked buttons and wax seals.

## Later (backlog)

* Your character shown in the inventory (a figure on the right page that
  turns with the mouse) — needs the player model (entity milestone).
