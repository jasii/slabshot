class_name SimConst
## Shared simulation constants. Server and client must agree on all of these.

const TICK_RATE := 60
const DT := 1.0 / 60.0

# Movement collider (vertical cylinder, feet at state.pos)
const PLAYER_RADIUS := 0.35
const PLAYER_HEIGHT := 1.9
const EYE_HEIGHT := 1.7
const STEP_HEIGHT := 0.55

# Slab hitbox (thin box, faces look direction)
const SLAB_WIDTH := 0.9
const SLAB_DEPTH := 0.08
const CRIT_FRACTION := 0.2  # top 20% of slab
const CRIT_MULT := 1.5

# Movement tuning
const GRAVITY := 22.0
const JUMP_VELOCITY := 7.5
const MAX_SPEED := 7.5
const GROUND_ACCEL := 80.0
const AIR_ACCEL := 18.0
const FRICTION := 9.0
const STOP_SPEED := 2.0
const MAX_FALL := 40.0

# Blade stance (hold Shift): slab turns edge-on to your aim, you move slowly
# and can't fire until fully turned back
const BLADE_TICKS := 6  # 0.1s to turn fully sideways (and back)
const BLADE_SPEED := 0.45  # movement multiplier when fully bladed

# Health
const MAX_HP := 100
const REGEN_DELAY_TICKS := 240  # 4s
const REGEN_PER_TICK := 25.0 / 60.0
const RESPAWN_TICKS := 150  # 2.5s
