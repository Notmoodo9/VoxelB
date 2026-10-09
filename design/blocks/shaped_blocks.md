# Shaped blocks (Milestone 7b)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09, 2 rounds.

## Summary
Non-cube blocks for the woods, the stone family, terracotta and glass:
slabs, stairs, fences, fence gates, doors, trapdoors, ladders, signs, wall
signs, pressure plates, walls, stacking pillars and glass panes.
Interaction (opening doors, placing, typing on signs, stepping on plates)
arrives with the player in M16; until then every variant (open/closed,
facings, halves) can be seen in the block gallery.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Materials | all 19 woods (16 trees + 3 mushrooms), stone family (8), terracotta (16 colours, not wool), glass panes |
| Wood shapes | slab, stairs, fence, fence gate, door, trapdoor, ladder, sign post, wall sign, pressure plate |
| Stone shapes | slab, stairs, wall, stacking pillar |
| Terracotta shapes | slab, stairs |
| Glass panes | glass, tinted glass and the 16 stained glasses; connect to each other and to solid blocks |
| Stair corners | automatic inner/outer corners where stairs meet at right angles |
| Pillar | stacking column: base at the bottom, smooth shaft, carved capital on top, chosen automatically when stacked; a lone pillar shows all three |
| Doors & trapdoors | a unique design per wood (see below) |
| Signs (later) | show text typed when placed (M16+); blank until then |
| Pressure plates (later) | open adjacent doors and trapdoors; also feed a future mechanism/wiring system (needs its own design) |

## Materials
* Woods: oak, birch, spruce, jungle, acacia, dark_oak, cherry, redwood, palm,
  mangrove, willow, maple, glowwood, crystalwood, frostwood, emberwood,
  red_mushroom, brown_mushroom, glowing_mushroom. Shapes use the planks
  texture (doors, trapdoors, ladders have their own).
* Stone family: stone, cobblestone, mossy_cobblestone, smooth_stone,
  stone_bricks, deep_stone, sandstone, bricks.
* Terracotta: the 16 colours.
* Panes: glass, tinted_glass, 16 stained glasses.

## Door and trapdoor designs (Claude's proposal, please correct)
| Wood | Design |
|---|---|
| oak | classic: two raised panels, iron handle |
| birch | pale planks with a 4-pane window at the top |
| spruce | heavy vertical planks with iron straps |
| jungle | woven slats with a leafy vine across |
| acacia | bright orange diagonal planks, small diamond window |
| dark_oak | deeply carved with a dark knot pattern, no window |
| cherry | pink panels with a round blossom-shaped window |
| redwood | tall vertical boards, red, arched top window |
| palm | horizontal slats (shutter style) |
| mangrove | red planks with a cross brace and a small square window |
| willow | pale olive planks with a curved hanging-leaf carving |
| maple | amber planks with a leaf carving in the centre |
| glowwood | teal planks with glowing cyan veins (glow layer) |
| crystalwood | lilac frame with translucent crystal panes |
| frostwood | icy planks with frosted window panes |
| emberwood | charcoal planks with glowing orange cracks (glow layer) |
| red / brown / glowing mushroom | stem-coloured door with a round porthole; glowing mushroom's porthole glows |

Ladders: two rails and rungs in the wood's colour, see-through between rungs.

## Block states (engine)
| Shape | Variants |
|---|---|
| slab | bottom, top |
| stairs | 4 facings × bottom/top (corners automatic) |
| fence, wall, pane | 1 (connections automatic) |
| fence gate | 4 facings × closed/open |
| door | 4 facings × lower/upper × closed/open × hinge left/right |
| trapdoor | 4 facings × bottom/top × closed/open |
| ladder, wall sign | 4 facings |
| sign post | 4 rotations |
| pressure plate | up / pressed |
| pillar | 1 (base/shaft/capital automatic) |

## Open
* Sign text rendering and editing: M16+.
* Pressure plate → mechanism system: own design later.
* More materials (wool, ores, …) can get shapes through data files at any time.
