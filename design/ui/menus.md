# Menus and UI look (Milestone 17 part 2) — design interview 2026-10-12

## Summary
Modern "glass" menus over a live 3D flyover of the world: translucent dark
panels with soft edges, flat buttons with a teal/turquoise accent and a hover
glow, a smooth SDF font, the title "VoxelB" as big styled text, and quick
slide/fade transitions.

## Decisions (owner's answers)
| Topic | Decision |
|---|---|
| Overall style | **Modern glass**: translucent dark panels with soft (rounded, blurred-backdrop) edges over the live world; flat buttons, bright accent, hover glow |
| Accent colour | **Teal / turquoise** (buttons, highlights, title gradient) |
| Main menu background | **Live flyover**: the engine slowly glides over a scenic spot, gentle blur under the panels |
| Flyover scene | **Sunset over mountains**: a slow glide along a river valley toward big mountains, golden-hour light, clouds, long shadows |
| Title | **Big styled text** "VoxelB": large, colour gradient (teal) and shadow; replaceable by a logo image later |
| Font | **Our own SDF font**: crisp at any size, outlines/glow; a clean readable typeface (menus and HUD) |
| Motion | **Smooth slides & fades** (~150 ms), buttons glow on hover, the world blurs behind the pause menu |
| Main menu buttons | **Play** (world list), **Settings**, **Credits / About**, **Quit** |
| World list | Name plus **mode & difficulty, last played, thumbnail** (screenshot at last save), **size on disk**; Create / Play / Delete |
| World creation | name, seed, mode, difficulty, hardcore toggle; modes/difficulties that aren't built yet are **shown greyed out** ("coming later"); the choices are stored in world.dat |
| Pause menu (Esc) | **Resume**, **Settings**, **Save & quit to menu**, **Save & quit game** |
| Settings | **Tabs + presets**: Graphics (Low/Medium/High/Ultra preset + every effect, render/LOD distance), Controls (rebind keys, sensitivity, invert), Game (FOV, autosave, HUD); live apply where possible, written back to the .cfg files |

## Technical choices (mine; DECISIONS.md when built)
* The flyover scene is a data file (seed, path points, time of day) so it
  can be changed without code.
* Credits / About: game name, version (milestone), "made with x86-64
  assembly", credits list from a data file.

## Still open
* Exact typeface for the SDF font (I'll generate it from a free, openly
  licensed font with a tool script and show you a screenshot).
* Sounds for hover/click: with audio (Milestone 24).
