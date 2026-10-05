# Slabshot

Minimal multiplayer arena FPS (Godot 4.7, GDScript). Players are flat slabs;
your slab faces where you aim; hold Shift to turn it edge-on while still
aiming forward (slow movement, no firing), or flick your aim away to dodge.

Godot: `C:\Tools\Godot\Godot_v4.7.2-stable_win64.exe` (console build alongside).

## Play

```
godot --path .                                          # main menu: browser, host, settings
godot --path . -- --host --dummies=6 --dummy-powerups   # practice vs dummies that use powerups
godot --path . -- --host --mode=tdm --upnp              # host Team Slayer, open router port
godot --path . -- --join=1.2.3.4:27500                  # join directly
```

Controls: WASD, Space jump, mouse aim/fire, hold Shift to blade (slab turns
edge-on, aim stays forward, you move at 45% speed and can't fire), Q / wheel / 1 / 2 switch weapon,
Tab scoreboard, F3 net graph, Esc free mouse, F10 leave.

## Content

Modes: **Free For All** (first to 25, 10 min) and **Team Slayer** (orange vs
cyan, first to 50, 12 min, no friendly fire). `--rotate` alternates them.

Weapons (Pulse always; one special from map pickups, limited ammo):

| Weapon | Behaviour |
|---|---|
| Pulse | 6 shots/s, 18 m/s bullets, 20 dmg |
| Rail | hold 0.6s to charge, fast 55 m/s bullet, one-shot kill, pierces, 1s cooldown |
| Ricochet | 2 shots/s, 16 m/s, bounces off walls twice, 35 dmg |
| Scatter | 1 shot/s, fan of 7 bullets at 15 m/s, 30m range, 12 dmg each |

Powerups (3 spots, random type, 30s respawn):

| Powerup | Effect |
|---|---|
| Split | two half-width slabs, each with 100 HP; both must die |
| Fold | quarter-size slab, 12% faster |
| Decoy | two copies of you (one mirrored); die in one hit, no kill credit |
| Mirror Face | front face reflects bullets back; back is exposed |
| Ghost | near invisible while still, fades in when moving/shooting |
| Spin | slab spins 2x/s |
| Overcharge | Pulse pierces and fires ~40% faster |
| Radar | see enemies through walls |

Top 20% of every slab is a crit strip (1.5x).

## Hosting

**Dedicated (Docker):** `docker compose -f docker/compose.yaml up -d --build`
runs the game server (UDP 27500 game, 27501 browser query) and the master list
(TCP 27580). Configure with env vars `SLAB_NAME`, `SLAB_MODE`, `SLAB_ROTATE`,
`SLAB_MAX`, `SLAB_SCORE`, `SLAB_TIME`. For the server to show up in other
people's browsers with the right address, set `MASTER_KEY` and
`SLAB_PUBLIC_HOST=<public ip or hostname>`.

**Komodo:** stack `slabshot` on RackNerd builds `deploy/compose.yaml` from this repo and
publishes UDP 27500-27501 directly on the VPS (no proxy needed). To update the
server: push to `main`, then redeploy the stack. Settings via the stack's
environment (`SLAB_NAME`, `SLAB_MODE`, `SLAB_ROTATE`, `SLAB_MAX`, ...).

**Dedicated (no Docker):** `godot --headless --path . -- --server --master=http://host:27580`

**Listen server:** Host tab in the menu (optional UPnP + master listing).

**Server browser:** Settings > Master server URL. LAN servers are found by
UDP broadcast automatically.

**Exports:** `export_presets.cfg` has Windows client, Linux client and Linux
dedicated server presets. Install export templates first (Editor > Manage
Export Templates), then e.g. `godot --headless --path . --export-release "Windows Client"`.

## Tests

```
godot --headless --path . --script res://tests/run_tests.gd
.\tools\run_local_test.ps1 -Bots 63 -Seconds 30 -ServerExtra "--mode=tdm"
python master/master.py                                 # local master on :27580
```

## Layout

- `sim/` shared deterministic simulation: movement, collision grid, hitboxes, Combat tracer, World, weapons, powerups
- `net/` protocol, lag compensation, net simulator, master heartbeat, UPnP
- `server/` authoritative 60Hz server, match rules, pickups, browser query responder
- `client/` prediction/reconciliation, interpolation, rendering, HUD, menu, server browser
- `maps/` box-list maps (geometry = collision = rendering)
- `master/` stdlib Python master server list
- `docker/` server image + compose

## Netcode summary

- Server-authoritative 60Hz tick; 30Hz delta snapshots (quantized, per-base cache).
- Client predicts own movement with the same `PlayerSim`, reconciles + replays on mismatch, smooths small errors.
- Remote players interpolated ~4 ticks in the past (adaptive to jitter).
- Inputs every tick with 3x redundancy; client clock steered by server-reported input slack.
- Bullets are slow projectiles with deterministic paths (straight lines + wall bounces). The server sends one spawn record per shot (repeated in 2 snapshots for loss); clients rebuild the path. Bullets are drawn on your predicted timeline and hit-tested by the server against present positions, so what you dodge on screen is what the server checks (favor the dodger). Bullets move on the GPU via a MultiMesh shader.
- Decoys are indistinguishable on the wire (the Decoy powerup flag is never sent).
