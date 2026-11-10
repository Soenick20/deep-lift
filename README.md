# Deep Lift: Phase 1 prototype

A playable slice of Deep Lift: the **prologue tutorial** on the surface, then the **mines**.
It is made to answer one question: **is it fun with 2 players?** (the Phase 1 gate in the design doc).

All art is generated from code. There are no asset files and no sound yet.

## How to run

1. Install **Godot 4.3 or newer** (standard version, not .NET): https://godotengine.org/download
2. Open Godot, click **Import**, choose this folder's `project.godot`.
   On a newer Godot it may offer to upgrade the project; say yes.
3. Press **F5** (Run).

## Controls

| | Player 1 (keyboard + mouse) | 2nd keyboard player | Controller (up to 4 players) |
|---|---|---|---|
| Join | Always in | Press an arrow key | Press A or Start |
| Move | WASD | Arrow keys | Left stick |
| Aim | Mouse (else move direction) | Move direction, with auto-aim | Right stick (else move direction, with auto-aim) |
| Shoot | Left mouse or Space | `.` | Right trigger or RB |
| Dig (hold) | Right mouse or F | `,` | Left trigger or X |
| Interact (pick up, feed, drop, hold to revive) | E | `/` | A |
| Place torch | Q | M | Y or LB |
| Swap gun (backpack) | R | N | B |

## The prologue (tutorial): the first night

The game starts on the surface on a stormy night. Each step shows its goal at the top of
the screen and the controls you need at the bottom. Press **Tab** (or **Back** on a controller) to skip it.

1. **Camp.** Walk around the campfire.
2. **Class tents.** Every player walks to a tent door and presses Interact to pick a role:
    - **Bodyguard** (red tent): shotgun, a wide close-range blast. Helmet with a red plume.
    - **Architect** (yellow tent): hand drill, digs and chops 2.2x faster. Hard hat with a lamp.
    - **Artificer** (blue tent): +4 torches, brighter torches, and crafts a torch from 2 ore
      when out of torches. Goggles and a tool backpack.
    When everyone has a role, the log gate opens.
3. **The trail.** Chop through the fallen trees and dig through the boulders.
4. **The dark woods.** It gets dark under the canopy: place torches. Critters sleep here,
   and noise (shooting, digging) wakes them.
5. **Critters.** Shoot them. They are slower in torchlight.
6. **The temple ruins.** A glowing heartstone sits on the altar. Pick it up: the carrier is slow and can't shoot.
7. **The escort.** The temple pulses and arrows point to the ancient tower. Critters attack on the way.
8. **The tower wakes.** Put the heartstone in. The tower's stone spire sinks, the creature
   opens its eyes, and you hold the platform for 12 seconds. Then it **blinks** into the mines.

Players who join after the class step get a role automatically.

## Loot

- **Guns:** Pistol, Shotgun, SMG and Rifle, each in **Common** (white), **Rare** (blue) or **Epic**
  (purple), with slightly random stats. Rifles pierce through enemies. Rarer guns get more likely the deeper you go.
- **Where loot comes from:** supply crates in cave rooms, better caches inside hidden pockets,
  and drops from crawlers (ore often, guns sometimes).
- **On the floor:** guns float with a beam in their rarity colour; press Interact to pick one up.
  Ore, torches and medkits are picked up by walking over them.
- **Backpack:** one gun in hand plus 2 spare. Picking up a gun when the pack is full drops your current one.
- **The lift stash:** ore you carry is stored when you step onto the lift. If you go down
  before that, you drop the ore you were carrying, and a teammate can grab it.
- **Lift stations** (spend stored ore): **Workbench** upgrades the gun in your hand one rarity
  (Common to Rare 6 ore, Rare to Epic 12), **Med bay** heals fully (3 ore), **Torch rack** gives 2 torches (2 ore).

## A mine floor, start to finish

The mines are drawn with voxels 4x finer than the gameplay grid (12.5 cm): rounded tunnels whose
rock walls rise from the floor in small ledges, solid rock that fades into darkness, wet patches,
stalagmites, and crystal clusters on ore. Ore veins glow and light up the tunnels around them, so
you can see the mine's shape from a distance, but you still need torches to light your own way.
Hidden pockets stay hidden (drawn as solid rock) until you dig into one.

1. **Blink in.** The crew starts on the living lift. Every few seconds the lift pulses
   and a cyan arrow by each player points *roughly* toward the heartshard.
2. **Explore.** Dig through dirt walls; dig glowing ore for Ore. Place torches: crawlers
   are slower in torchlight. Shooting and digging make noise that wakes sleeping crawlers ("z z").
3. **The threat meter** rises over time and with noise. When it fills, a group of crawlers comes hunting.
4. **Find the heartshard.** Its room is sealed by grey-blue hard rock you must dig through. Crawlers guard it.
5. **Carry it back.** The carrier is slow and cannot shoot or dig; the others protect them. Arrows now point home.
6. **Feed and hold.** Interact on the lift to feed it. Hold the platform for 20 seconds against a swarm.
7. **Blink.** The lift jumps to the next depth: a new random mine, a bit harder.

When a player's health hits 0 they are downed; a teammate holds Interact next to them to revive.
If everyone is down, the run ends; press Interact to dive again.

## What to judge in playtests (Phase 1 gate)

- Is moving, shooting and digging satisfying with 2 players on one screen?
- Does the darkness feel tense rather than annoying? Are torches worth placing?
- Is carrying the shard back a fun co-op moment?
- Is the 20-second hold a good climax, too easy, or too hard?
- Do floors feel different enough from each other?

## Tuning knobs

| What | Where |
|---|---|
| Player speed, carry slowdown, fire rate, health | `scripts/player.gd` (top) |
| Crawler speed, sight range, attack | `scripts/crawler.gd` (top) |
| Charge time, leash distance, torch light radius | `scripts/game.gd` (top) |
| Gun stats, rarity odds, upgrade costs | `scripts/loot.gd` |
| Threat rate, swarm sizes | `scripts/game.gd`, `_update_state` and `emit_noise` |
| Map size, wall height, dig times, rooms, ore | `scripts/level.gd` |
| Cave look: rock height, how fast walls rise, where rock fades to darkness | `scripts/level.gd`: `HMAX`, `RISE`, `VOID` |
| Characters, crawler, lift, shard models | `scripts/voxel_kit.gd` |

## Files

- `scripts/game.gd`: floor flow, camera, lift, shard, noise and threat, swarms, HUD, joining
- `scripts/prologue.gd`: tutorial steps, rain, lightning, campfire, dark woods, the waking tower
- `scripts/level.gd`: mine and surface generators, diggable chunked voxel walls, ore lights, pathfinding
- `scripts/player.gd`, `scripts/player_input.gd`: player actions, animation, input devices
- `scripts/crawler.gd`: the monster (sleep, investigate noise, chase, attack)
- `scripts/loot.gd`: weapon types, rarities, stat rolls and loot odds
- `scripts/voxel_kit.gd`: builds all models from voxels
- `screenshots/`: images rendered from this build

## Developer commands

Run the automated play-through (no window). It plays the whole prologue (move, pick classes,
gate opens, chop the trail, wake and clear the critters, find the heartstone, feed the tower,
first jump), then a mine floor (sealed shard room, dig in, kill a crawler, wake one with noise,
carry and feed the shard, blink to depth 2), then revive, game over and restart:

```bash
godot --headless --path . -- --autotest
```

Start straight in the mines, without the tutorial:

```bash
godot --path . -- --skip-tutorial
```

Render the screenshots again:

```bash
godot --path . -- --shot=/full/path/to/screenshots
```

## Not in this prototype yet

Sound, class abilities beyond the tent upgrades, the branching map with Vault and Mini-boss
floors, more monster types, and menus. Those are Phase 2 and later in the design doc.
