# Old-growth forest (Milestone 10, part 2)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Rare, magnificent hearts inside forests: giant oaks with realistic,
tapering trunks (a wide flared base with roots, narrowing to about 3×3,
then splitting into heavy branches), a mix of huge and colossal sizes, with
normal oaks, birches and bushes beneath. Mossy ground, many ferns, huge
roots, mushroom rings in glades, and a dim, deep-green feel.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Rarity | rare pockets inside forests: ~1 in 6 forests has an old-growth heart, 300–800 blocks across |
| Giants | a mix of huge and colossal, leaning colossal; realistic shape: wide trunk base that tapers (to ~3×3 and narrower) and then splits into branches |
| Species | giant oaks, with smaller oaks, birches and bushes filling the understorey |
| Floor | moss and ferns, huge roots spreading from the trunks, mushroom rings in small glades, dim and misty (mist arrives with fog in M14; darker colours now) |

## Shape of a giant (engine: new tree kind `giant`)
* Height 30–65 (about half above 45).
* Trunk is a stack of discs whose radius shrinks with height: base radius
  3–4.5 (with flare: wider in the lowest 3 blocks), about 1.5 (3×3) at the
  crown base, ~1 at the top.
* Roots: 4–7 log runs from the base outwards and down, 5–10 blocks long,
  arching over the ground.
* From ~55% of the height: 4–8 heavy branches (log runs, thick at the
  trunk) rising outwards, each ending in a large leaf cluster; a crown
  cluster on top. Crown spread 10–18 blocks.

## New blocks
* `moss_block` (soft green ground), `fern`, `red_mushroom`,
  `brown_mushroom` (shared with forest).

## Numbers (Claude's proposal, in `data/biomes/31_old_growth_forest.biome`)
| Item | Proposal |
|---|---|
| Climate | inside the forest's box: humid and mild; a third "weirdness"-like field picks the pockets |
| Colours | grass 2F8F2A, foliage 25761C (deeper and darker than forest) |
| Giants | ~1 per 45×45 blocks |
| Understorey | small oaks, birches, bushes ~1 per 12×12 |
| Floor | moss block top (60%), grass elsewhere; ferns 30%, short grass 10% |
| Mushroom rings | one candidate per 128×128 blocks, ring radius 3–5 |

## As built (M10 part 2)
* Data in `data/biomes/31_old_growth_forest.biome`, the giant in
  `10_trees.biome` (`kind = giant`).
* After seeing the first version, branches were made longer (H/7 to H/5,
  up to 12), more numerous (6–10) and start lower (45–87%), with larger leaf
  clusters (radius 4.5–6.5) and wider bases (3.5–5): wide, layered
  canopies.
* Moss patches use a yellow-olive moss block so they read apart from the
  grass.

## Open
* Mist: with fog in M14.
