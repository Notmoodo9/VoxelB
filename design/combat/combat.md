# Combat: melee, ranged, armor, runes (Milestone 21)

Design interview with the owner, 2026-10-15. Everything numeric is data
(item files, `data/combat/*.cfg`) so it can be tuned without assembly.
Hostile mobs come in M22, so until then the animals are the only targets
(and the boars' and goats' rams the only attacks on the player); magic is
M27, temperature gear M28.

## Summary
Timing-based melee in the Minecraft 1.9 style: every weapon has a swing
speed and a meter under the crosshair; a full swing does full damage.
Four melee weapon types (sword, axe, spear, mace) in the eight tool tiers,
plus rare named weapons later. Bows, crossbows, slings and throwables with
real projectile flight. Armor in four pieces, in light / medium / heavy
weights per tier (leather, chain, plate), a shield in the off hand, and two
accessory slots. Runes socketed at the Tinker's table upgrade weapons,
armor and tools. Crits, sweeps, shield blocking and a dodge roll.

## Decisions (owner)
| Topic | Decision |
|---|---|
| Melee feel | swing cooldown: a meter under the crosshair refills; damage scales with how full it is |
| Melee weapons | swords, axes (also chop), spears (reach, can be thrown), maces / hammers |
| Weapon tiers | the 8 tool tiers (wood → star crystal) plus rare **named weapons**: the system now (data), the weapons themselves with dungeons and bosses (M23, M29) |
| Ranged | bow, crossbow, throwables (spears, knives, rocks, snowballs), sling |
| Ammunition | arrowheads in tiers (more damage) plus fire arrows now; poison, explosive and magic arrows later. Crossbows shoot bolts the same way, slings pebbles |
| Armor pieces | helmet, chestplate, leggings, boots + a shield in the off hand + 2 accessory slots (items for them later: magic, bosses, trading) |
| Armor weights | light / medium / heavy in every tier: light = leather or cloth trimmed with the tier's metal, medium = chainmail / scales, heavy = plate; a leather-only light set at the start |
| Weight trade-off | protection vs mobility: light no slowdown and the quickest dodge; medium a little slower; heavy the most protection, slower walking, more hunger, no dodge roll |
| Upgrades | **runes** made from gems and ores, socketed at the Tinker's table; more sockets in better tiers; a rune can be removed but breaks |
| Rune families | combat, defence, elements, utility (all four) |
| Mechanics | critical hits (falling), shield blocking (axes and maces can knock the shield down), sweep attacks (full sword swing), dodge roll |
| Hit feedback | a tiny hit pause and camera shake; sparks on crits, dust on knock-back; no damage numbers or health bars |
| Armor HUD | a row of 10 shield icons above the hearts while armor is worn (journal ink) |
| Inventory | a paper doll on the journal's left page: 4 armor slots down its side, the off hand (shield) and 2 trinket slots below |
| Dodge key | double-tap A / D / S (W stays sprint); rebindable to one key |

## My choices (numbers, to check)
### Melee
Damage in health points (the player has 20). Damage × (0.2 + 0.8 × meter²)
so a spammed swing does a fifth. Reach 3 blocks (spear 4).

| Tier | Sword | Axe | Spear | Mace |
|---|---|---|---|---|
| wood | 4 | 6 | 3.5 | 6 |
| stone | 5 | 7 | 4 | 7 |
| copper | 5.5 | 7.5 | 4.5 | 8 |
| iron | 6 | 8 | 5 | 9 |
| diamond | 7 | 9 | 6 | 10 |
| mythril | 8 | 10 | 7 | 11 |
| adamantite | 9 | 11 | 8 | 12 |
| star crystal | 10 | 12 | 9 | 13 |
| swing time | 0.6 s | 1.0 s | 0.55 s | 1.4 s |
| knock-back | ×1 | ×1 | ×0.7 | ×2 |

* The hand: 1 damage, 0.25 s. Tools that are not axes: 2–4 by tier, 0.8 s.
* Weapons wear 1 per hit (tools 2 per hit); the tool durability table
  applies; repaired at the Tinker's table like tools.
* **Crit**: a full swing while falling (after a jump, not on a ladder or
  in water): × 1.5, sparks, a stronger pause and shake.
* **Sweep**: a full sword swing on the ground also hits everything within
  1 block of the target for 1 + 30 % of the damage.
* **Axe / mace vs shield**: a full swing on a raised shield knocks it
  down for 3 s (mace 5 s).
* **Spear throw**: hold right click 0.5 s, release: flies like an arrow,
  damage + 2, sticks where it lands and is picked up again (wear 2).
* **Hit feel**: a 50 ms pause (crit 80 ms, mace 100 ms) and a small camera
  shake; dust where knock-back pushes.

### Ranged
| Weapon | How | Full charge | Projectile speed | Notes |
|---|---|---|---|---|
| bow (wood, iron, diamond, star crystal) | hold to draw | 1.0 s | up to 50 b/s | damage × draw; a full draw can crit (sparkle trail) |
| crossbow (iron, diamond, star crystal) | hold to load, click to fire | 1.25 s load | 70 b/s, flatter | +2 damage; stays loaded |
| sling | hold to spin | 0.6 s | 30 b/s | pebbles (from gravel/stone), 2–3 damage |
| throwing knife (copper → star crystal) | right click | — | 30 b/s | 3–7 damage, stack of 16 |
| rock / snowball | right click | — | 25 b/s | 1 damage / 0 (knock-back only) |

* **Arrows** = stick + arrowhead + feather (4 arrows): stone 4, copper 5,
  iron 6, diamond 7, mythril 8, adamantite 9, star crystal 10 damage at
  full draw. **Fire arrows** (arrow + coal): the target burns 4 s.
  Bolts = the same with 2 sticks; pebbles from cobblestone.
* Bowstring and crossbow string from plant fibre (twine).
* Projectiles fly with gravity and drag, stick into blocks and creatures,
  and can be picked up again (fired arrows 75 % of the time).

### Armor
Protection points P (summed over the pieces); damage taken × (1 − 0.04 ×
min(P, 20)), so 20 points block 80 %. A set splits as helmet 15 %,
chestplate 40 %, leggings 30 %, boots 15 % (rounded to half points).

| Tier | Light (leather) | Medium (chain) | Heavy (plate) |
|---|---|---|---|
| leather | 5 | — | — |
| copper | 6 | 9 | 12 |
| iron | 7 | 11 | 14 |
| diamond | 9 | 13 | 16 |
| mythril | 10 | 14 | 18 |
| adamantite | 11 | 16 | 19 |
| star crystal | 12 | 17 | 20 |

* **Mobility** (scaled by how much of the set is worn): light none;
  medium −5 % speed; heavy −12 % speed, +25 % hunger from moving, no dodge
  roll.
* Armor wears 1 per hit taken (not falls or starvation); repaired at the
  Tinker's table.
* Light = leather + the tier's bars; medium = chain links (bars → links
  at the workbench); heavy = plates (bars hammered into plates at the
  Tinker's table).
* **Shield** (wood, copper, iron, diamond, mythril, adamantite, star
  crystal): hold right click with it in the off hand (0.25 s to raise):
  blocks everything from the front 90°, walk at sneak speed; wears by the
  damage blocked.
* **Dodge roll**: 0.35 s, 3 blocks, no damage during the first 0.2 s,
  1.5 s cooldown, 0.3 exhaustion; medium armor rolls 2 blocks; heavy: no.
* **Accessory slots**: 2, shown now; no items until magic / bosses /
  trading.

### Runes
A **rune** = a blank runestone (stone + crystal shard at the Tinker's
table) + its material. Socketed at the Tinker's table; clearing a socket
destroys the rune. Sockets: wood, stone, leather 0; copper, iron 1;
diamond, mythril 2; adamantite, star crystal 3 (shields and bows by their
tier). The same rune twice stacks (up to its max).

| Family | Rune | On | Effect | Material |
|---|---|---|---|---|
| combat | Sharpness | melee | +1 damage (max 3) | diamond |
| | Knock-back | melee | +50 % knock-back (max 2) | goat horn |
| | Swiftness | melee, bows | −15 % swing / draw time (max 2) | rabbit's foot |
| | Piercing | bows, crossbows | arrows go through 1 more target (max 2) | antler |
| defence | Protection | armor, shields | +1 protection point (max 3) | iron bar |
| | Thorns | armor | 15 % chance the attacker takes 2 (max 3) | cactus |
| | Feather | boots | −40 % fall damage (max 1) | feather |
| | Fire ward | armor | −25 % fire and lava damage (max 2) | gold bar |
| elements | Fire | melee, bows | the target burns 3 s | coal + amber crystal |
| | Frost | melee, bows | the target is slowed 40 % for 3 s | blue crystal |
| | Storm | melee | 10 % chance of a spark: +3 damage | purple crystal |
| utility | Unbreaking | anything | −40 % wear (max 2) | silver bar |
| | Looting | melee | +1 to creature drops (max 2) | emerald |
| | Fortune | pickaxes | +1 to ore drops (max 2) | star essence |

### Named weapons
A `[named <id>]` record in the item files: a base weapon, its own name,
texture, fixed runes and sockets, and a short line of lore shown in the
tooltip. None exist yet: each one is interviewed with the dungeon or
boss that drops it.

## Build plan
1. **Melee**: the swing meter, the weapon items (4 types × 8 tiers),
   damage / knock-back / crits / sweeps, hit pause and shake, sparks and
   dust, wear.
2. **Armor**: the paper doll page, armor items in 3 weights, protection,
   mobility, the HUD shield row, shields and blocking, the dodge roll,
   accessory slots.
3. **Ranged**: projectiles (flight, sticking, pick-up), bows, crossbows,
   slings, throwing knives, rocks, snowballs, spear throws, arrows /
   bolts / pebbles, fire arrows.
4. **Runes**: runestones, the 14 runes, sockets and the Tinker's table
   page, the effects; the named-weapon record.

## Built
* **Part 1 (v0.21.1)**: the swing meter (a bar under the crosshair),
  swords, spears and maces in the 8 tiers and the axes as weapons, crits,
  sweeps, knock-back, wear, the hit pause, camera shake, sparks and dust
  (data/combat/combat.cfg). Try it: hit a cow with a sword, wait for the
  bar; jump and hit as you fall.

## Still open
* What the armor looks like on the player (no third-person view yet).
* Rune glyph art and colours (my choice unless the owner wants to pick).
* Accessories, named weapons, poison / explosive / magic arrows: later.
