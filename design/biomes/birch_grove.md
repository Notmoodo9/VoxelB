# Birch grove (Milestone 10, part 3)

Status: **approved by the owner** (2026-10-09). Interview: 2026-10-09.

## Summary
Small, bright and airy birch groves (100–300 blocks) found inside about one
in every few forests: white trunks with light yellow-green leaves, spaced so
sunlight reaches a grassy floor full of small spring flowers, rare bluebell
carpets, a few mushrooms and fallen white birch logs.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Feel | bright and airy: white trunks, light yellow-green leaves, sunlit floor |
| Size / rarity | small pockets inside forests, 100–300 blocks, roughly one per few forests |
| Density | medium: a birch every ~6–9 blocks, with gaps for light |
| Floor | grass and wildflowers, mushrooms and fallen birch logs, rare bluebell carpets |
| New flowers | lily of the valley, bluebell, wood anemone |
| Leaves | light yellow-green |

## Numbers (Claude's proposal, in `data/biomes/32_birch_grove.biome`)
| Item | Proposal |
|---|---|
| Placement | the forest's climate box, low weirdness (0–0.18), priority 1 |
| Trees | birch (tall, slim, 7–10 trunk) ~1 per 60 blocks²; a few small oaks |
| Colours | grass 6CC93A (lighter than forest), foliage 7CC83A |
| Floor | short grass 30%, tall grass 4%; flowers (lily of the valley, bluebell, wood anemone, oxeye daisy, dandelion) 5% in clusters |
| Bluebell carpets | one candidate per 128×128 blocks (35%), radius 8–16, 70% bluebells |
| Mushrooms | brown and red, 1% of the floor |
| Fallen birch logs | ~1 per 1500 blocks², 3–5 long |

## As built (M10 part 3)
* Data in `data/biomes/32_birch_grove.biome`; weirdness 0–0.21 gives
  groves on ~0.9% of land near the origin (forest 12.9%).
* Bluebell carpets are meadows with their own cell size (128) and flower
  list (`meadow_cell`, `meadow_flowers`).

## Open
* Golden autumn birches: not now (could be a seasonal variant later).
