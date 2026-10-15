# Survival: health, hunger, damage, death, difficulties (Milestone 20)

Design interview with the owner, 2026-10-14/15. Everything numeric is
data (`data/survival/*.cfg`, food values in the item files) so it can be
tuned without assembly. Temperature and thirst (Extreme/Ultra) are M28;
mob and weapon damage are M21–22.

## Summary
Minecraft-like survival in the journal style: ten hearts and ten food
icons above the hotbar, hunger with a hidden saturation reserve, hold to
eat, raw meat risky, damage from falls, drowning, lava and fire,
suffocation, cactus, the void, animal rams and starvation. On death the
world's chosen rule decides what happens to the items (drop, a gravestone,
or keep them on easy difficulties); a journal death page; respawn at the
world spawn. Hardcore deaths leave the world to spectate or delete.

## Decisions (owner)
| Topic | Decision |
|---|---|
| HUD | icon rows: 10 hearts left, 10 food icons right, just above the hotbar, journal ink-and-parchment style; hearts shake when low, food icons jitter when starving |
| Hunger | Minecraft-like: hunger meter + hidden saturation; good food fills both; regenerate while nearly full; starvation damage at zero; sprinting, jumping, mining, swimming and healing burn food |
| Death rule | a world option chosen on the create-world page, default **drop everything**; also **gravestone** and **keep inventory** (keep inventory only below Hard) |
| Gravestone | a small mossy headstone with your name and the day you died; right-click puts everything back into your slots (what does not fit drops); stays until emptied, then crumbles; its coordinates on the death page |
| Damage sources | falls, drowning, lava/fire, suffocation, cactus, the void, animal rams (boars, goats), starvation |
| Difficulties | scaling: Peaceful no hunger drain and fast regeneration; Normal standard; Hard more damage taken, faster hunger, starvation can kill; Extreme/Ultra harder still (Ultra: no natural regeneration) |
| Hardcore death | the death page offers "Spectate the world" or "Delete the world"; the world list marks it and only opens it in spectator mode |
| Eating | hold right-click ~1.6 s (food bobs at the mouth, crumbs), only when not full (milk always); slow walk while eating |
| Raw food | cooked meat fills a lot, raw little; raw chicken and rabbit may poison you (hunger drains fast ~30 s, food icons turn green); milk cures poisoning |
| Death page | the world fades to sepia; a journal page "You died", how, the day and where; Respawn / Main menu (Hardcore: Spectate / Delete) |
| Respawn | at the world spawn (a safe spot near it); beds later |

## My choices (numbers, to check)
* **Health 20** (10 hearts), **hunger 20** (10 icons), **saturation**
  0–hunger (starts at 5). **Exhaustion** adds up; every 4.0 takes one
  saturation point, or one hunger point when saturation is 0:
  sprinting 0.1 per block, swimming 0.01 per block, a jump 0.05 (sprint
  jump 0.2), a block mined 0.005, damage taken 0.1, one health healed 6.0.
* **Regeneration** (Normal): hunger 20 with saturation → 1 HP every
  0.5 s; hunger ≥ 18 → 1 HP every 4 s.
* **Starvation**: hunger 0 → 1 HP every 4 s; stops at 10 HP on Peaceful
  (no drain there anyway), at 1 HP on Normal, kills on Hard and above.
* **Difficulty table**

  | | damage taken | hunger drain | regeneration | starvation |
  |---|---|---|---|---|
  | Peaceful | ×0.5 | none | 1 HP / s whatever the hunger | — |
  | Normal | ×1 | ×1 | as above | down to 1 HP |
  | Hard | ×1.5 | ×1.25 | as above | kills |
  | Extreme | ×1.75 | ×1.5 | only at hunger 20, 1 HP every 6 s | kills |
  | Ultra | ×2 | ×1.75 | none (food and later potions only) | kills |

* **Falls**: (blocks fallen − 3) HP; landing in water (or on a
  climbable/plant-free liquid) takes none; flying never.
* **Drowning**: 15 s of air (10 bubbles shown over the food row while
  under water); then 2 HP a second. Air refills fast above water.
* **Lava** 4 HP every 0.5 s; **fire** (after lava) 1 HP a second for
  8 s, put out by water. **Suffocation** (head in a solid block) 1 HP
  every 0.5 s. **Cactus** 1 HP every 0.5 s while touching. **Void**
  (below y −320) 4 HP every 0.5 s.
* **Rams**: boar 4 HP, goat 2 HP (mob key `ram_damage`).
* After a hit, **0.5 s** without further damage (except the void); the
  screen edge flashes red and the view tilts a little.
* **Food** (hunger, saturation; ~ Minecraft):

  | Food | hunger | saturation | note |
  |---|---|---|---|
  | cooked beef, cooked pork, cooked venison | 8 | 12.8 | |
  | cooked mutton | 6 | 9.6 | |
  | cooked chicken | 6 | 7.2 | |
  | cooked rabbit | 5 | 6.0 | |
  | beef, pork, venison | 3 | 1.8 | |
  | mutton | 2 | 1.2 | |
  | chicken, rabbit | 2 | 1.2 | 30% food poisoning |
  | carrot | 3 | 3.6 | |
  | berries | 2 | 0.4 | eaten faster (0.8 s) |
  | milk bucket | 2 | 1.0 | always drinkable; cures poisoning; leaves the bucket |

* **Food poisoning**: 30 s, +0.5 exhaustion a second (about 2.5 hunger
  points lost), green food icons.
* **Dropped items on death** vanish after 5 minutes (the normal item
  drops keep their current rules).
* **Keep inventory** greys out when the difficulty is Hard or above; a
  world raised to Hard switches to the gravestone.
* **Death causes** shown: fell from a high place, drowned, burned in
  lava, burned to death, suffocated in a wall, pricked to death by a
  cactus, fell out of the world, was rammed by a boar/goat, starved.

## Built
* **Part 1 (v0.20.1)**: health, hunger and saturation with the HUD rows
  (hearts, food, air bubbles, green food when poisoned, shaking and
  jittering), exhaustion, regeneration and starvation by difficulty, all
  the damage sources, hold-to-eat with the food values above, food
  poisoning and milk, the red flash after a hit, death (everything drops)
  with the journal death page and respawn at the world spawn.
  Try it: a Survival world, eat with the right button held; `--test-block
  water` (or `lava`, `stone`, `cactus`) next to the player.
* Part 2 (next): the death rule on the create-world page (drop /
  gravestone / keep inventory), the gravestone, Hardcore spectate or
  delete.

## Still open
* The death rule is changeable later from the pause menu (my
  suggestion; the owner chose "default Drop" at creation).
* Beds and other respawn points (furniture, later).
* Armor and damage types (M21); mob damage (M21–22); temperature and
  thirst (M28); potions (M27).
