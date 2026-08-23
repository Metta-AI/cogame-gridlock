## Gridlock core types and constants.
##
## Everything the step loop touches lives here so the rule modules
## (graph / traffic / parcels / rules) can import ONE module and never form a
## cycle. Forked in shape from paintbot's `src/ctf/sim_types.nim`: the
## constants block, the map globals, and the rule that the wire record field
## order is sacred. Paintbot's continuous-motion family (MotionScale, Accel,
## MaxSpeed, ...) is deliberately absent — traffic on a road network is a
## queueing lattice, not a physics sim, so the whole step is integer and the
## native and emscripten builds agree bit for bit.
##
## GVnn (short rule name): HEADLINE  — prepend-only changelog on GameVersion.
## GV1 (gridlock v1): 9x9 signalised grid, 4 fleets x 50 vans, cell lattice,
##   fixed-time two-phase signals, spillback by one-vehicle-per-cell.

import std/[json, strutils, unicode]

const
  GameVersion* = "1"
    ## Rules gate recorded in every replay.

  TargetFps* = 24
  ReplayFps* = 24
  PlaybackSpeeds* = [1, 2, 3, 4, 8, 16]

  GridCols* = 9
  GridRows* = 9
  NodeCount* = GridCols * GridRows        ## 81 intersections
  DistrictCols* = 3
  DistrictRows* = 3
  DistrictCount* = DistrictCols * DistrictRows
  Seats* = 4
  LaneCount* = 288                        ## 144 segments x 2 directions
  SegmentCount* = 144

  NodeSpacingPx* = 112
  MarginPx* = 64
  CellPxDefault* = 8
  LaneOffsetPx* = 6
  LaneCellsDefault* = 14
  MapWidth* = 1024
  MapHeight* = 1024

  DockedLane* = -1
  DockedSentinel* = 65535                 ## lane id written for a docked van

  MaxNoteRunes* = 140
  MaxSayRunes* = 32
  MaxPolicyRunes* = 48
  MaxDetailRunes* = 200
  MaxPromptRunes* = 4000

  ReplayProtocol* = "gridlock.replay.v1"
  PlayerProtocol* = "gridlock.player.v1"
  ReplayFormatVersion* = 1

  FleetAliases*: array[Seats, string] =
    ["Copper", "Cobalt", "Verde", "Saffron"]
  FleetColours*: array[Seats, string] =
    ["#e07a3f", "#4a8fe7", "#5fbf6a", "#f2c14e"]
  DepotNodes*: array[Seats, array[2, int]] =
    [[1, 1], [7, 1], [1, 7], [7, 7]]
  DistrictNameTable*: array[DistrictCount, string] =
    ["NW", "N", "NE", "W", "CENTRE", "E", "SW", "S", "SE"]
  ArterialLines* = [2, 4, 6]

type
  GridlockError* = object of CatchableError

  PlayerConfig* = object
    name*: string

  GameConfig* = object
    tokens*: seq[string]
    players*: seq[PlayerConfig]
    seed*: int
    numAgents*: int
    fleetSize*: int
    episodeTicks*: int
    turnTicks*: int
    moveTicks*: int
    serviceTicks*: int
    dispatchPeriodTicks*: int
    laneCells*: int
    cellPx*: int
    loadTicks*: int
    orderPeriodTicks*: int
    backlogMax*: int
    signalCycleTicks*: int
    greenNsTicks*: int
    routeBudgetPerTick*: int
    jamThreshold*: int
    turnBudgetSeconds*: float
    minTurnSpacingSeconds*: float
    wallClockBudgetSeconds*: float
    playerConnectTimeoutSeconds*: float
    episodeTimeoutSeconds*: int
    cityPath*: string
    showPlayerLabels*: bool
    gameOverTicks*: int
    maxOutputTokens*: int
    model*: string

  Priority* = enum
    prNear = "near"
    prFar = "far"
    prFifo = "fifo"

  PlanSource* = enum
    psScripted = "scripted"
    psLlm = "llm"
    psFallback = "fallback"

  RoutingPlan* = object
    ## The six integers/enums plus two short strings a seat sets each turn.
    ## This record IS the policy interface; the router applies it to all
    ## fifty vans deterministically.
    congestionWeight*: int
    patience*: int
    dispatch*: int
    spread*: int
    corridor*: int          ## district index 0..8, or -1
    avoid*: int             ## district index 0..8, or -1
    priority*: Priority
    note*: string
    say*: string
    source*: PlanSource
    latencyMs*: int

  VehState* = enum
    vsDocked = 0
    vsLoaded = 1
    vsEmpty = 2
    vsStalled = 3

  Vehicle* = object
    fleet*: int             ## seat slot
    lane*: int              ## DockedLane when at the depot
    cell*: int
    state*: VehState
    hasParcel*: bool
    parcelId*: int          ## -1 when empty handed
    dest*: int              ## node index of the parcel destination, -1 none
    target*: int            ## node the van is currently driving to
    route*: seq[int]        ## lane ids, route[0] is the lane it occupies
    loadTicksLeft*: int     ## > 0 while loading
    waiting*: bool          ## loaded and waiting for a dispatch slot
    lastMoveTick*: int
    releaseTick*: int
    queued*: bool           ## already on the pending-replan FIFO

  Parcel* = object
    id*: int
    fleet*: int
    dest*: int
    createdTick*: int

  PlanRecord* = object
    turn*: int
    seat*: int
    plan*: RoutingPlan

  Keyframe* = object
    t*: int
    d*: uint32
    delivered*: array[Seats, int]
    onRoad*: array[Seats, int]
    backlog*: array[Seats, int]
    jam*: int

  SimEventKind* = enum
    seMatchStart = "match_start"
    seTurnStart = "turn_start"
    sePlan = "plan"
    seFallback = "fallback"
    seBudgetGuard = "budget_guard"
    seDeliver = "deliver"
    seJam = "jam"
    seJamClear = "jam_clear"
    seGridlock = "gridlock"
    seHeat = "heat"
    seMeter = "meter"
    seEnd = "end"

  GameEvent* = object
    kind*: SimEventKind
    t*: int
    turn*: int              ## -1 when not meaningful
    body*: JsonNode

  FallbackCause* = enum
    fcTimeout = "timeout"
    fcParseError = "parse_error"
    fcTransportError = "transport_error"
    fcNoCredentials = "no_credentials"
    fcBudgetGuard = "budget_guard"

  Pcg32* = object
    state*: uint64
    inc*: uint64

# ---------------------------------------------------------------------------
# PCG32. Integer only, so the native and wasm builds draw the same numbers.
# ---------------------------------------------------------------------------

const PcgMultiplier = 6364136223846793005'u64

proc step(rng: var Pcg32) {.inline.} =
  rng.state = rng.state * PcgMultiplier + rng.inc

proc next*(rng: var Pcg32): uint32 =
  let old = rng.state
  rng.step()
  let xorshifted = uint32(((old shr 18) xor old) shr 27)
  let rot = uint32(old shr 59)
  (xorshifted shr rot) or (xorshifted shl ((32'u32 - rot) and 31'u32))

proc initPcg32*(seed: int): Pcg32 =
  ## Canonical pcg32_srandom_r with a fixed stream selector.
  result.state = 0'u64
  result.inc = ((uint64(seed) and 0x7FFF_FFFF'u64) shl 1) or 1'u64
  result.step()
  result.state = result.state + uint64(seed)
  result.step()

proc rand*(rng: var Pcg32, bound: int): int =
  ## Uniform in 0 ..< bound (bound > 0).
  if bound <= 1:
    return 0
  int(rng.next() mod uint32(bound))

# ---------------------------------------------------------------------------
# Rune-safe truncation. NEVER slice a recorded string by byte index: a
# byte-truncated multi-byte character renders in a browser and fails a strict
# JSON/UTF-8 parser, which is exactly the replay bug the playbook warns about.
# ---------------------------------------------------------------------------

proc clipRunes*(text: string, limit: int): string =
  ## `text` cut to at most `limit` runes, on a rune boundary.
  if limit <= 0:
    return ""
  if text.runeLen <= limit:
    return text
  text.runeSubStr(0, limit)

proc cleanLine*(text: string, limit: int): string =
  ## One-line, whitespace-normalised, rune-truncated. Used for every string
  ## that reaches the replay.
  var flat = newStringOfCap(text.len)
  for rune in text.runes:
    if rune == Rune('\n') or rune == Rune('\r') or rune == Rune('\t'):
      flat.add(' ')
    else:
      flat.add($rune)
  clipRunes(strutils.strip(flat), limit)

# ---------------------------------------------------------------------------
# Grid helpers used by every module.
# ---------------------------------------------------------------------------

proc nodeIndex*(ix, iy: int): int {.inline.} = ix + GridCols * iy
proc nodeX*(n: int): int {.inline.} = n mod GridCols
proc nodeY*(n: int): int {.inline.} = n div GridCols

proc districtOfNode*(n: int): int {.inline.} =
  (nodeX(n) div 3) + DistrictCols * (nodeY(n) div 3)

proc districtName*(d: int): string =
  if d < 0 or d >= DistrictCount: "-" else: DistrictNameTable[d]

proc districtIndex*(bx, by: int): int {.inline.} = bx + DistrictCols * by
proc districtX*(d: int): int {.inline.} = d mod DistrictCols
proc districtY*(d: int): int {.inline.} = d div DistrictCols

proc nodePixelX*(n: int): int {.inline.} = MarginPx + NodeSpacingPx * nodeX(n)
proc nodePixelY*(n: int): int {.inline.} = MarginPx + NodeSpacingPx * nodeY(n)

proc manhattan*(a, b: int): int {.inline.} =
  abs(nodeX(a) - nodeX(b)) + abs(nodeY(a) - nodeY(b))

proc mirrorNode*(n, depot: int): int =
  ## `mirror_j` from the design note: depot 0 identity, 1 flips x, 2 flips y,
  ## 3 flips both. Demand is therefore identical up to symmetry for all four
  ## fleets, which is what makes the score comparison exact.
  var ix = nodeX(n)
  var iy = nodeY(n)
  if depot == 1 or depot == 3:
    ix = GridCols - 1 - ix
  if depot == 2 or depot == 3:
    iy = GridRows - 1 - iy
  nodeIndex(ix, iy)

proc isArterialCol*(ix: int): bool {.inline.} =
  ix == 2 or ix == 4 or ix == 6

proc isArterialRow*(iy: int): bool {.inline.} =
  iy == 2 or iy == 4 or iy == 6

proc depotNode*(depot: int): int {.inline.} =
  nodeIndex(DepotNodes[depot][0], DepotNodes[depot][1])

# ---------------------------------------------------------------------------
# The authored city, and the whole mutable episode state.
#
# `Sim` lives here (rather than in sim.nim) so every rule module imports ONE
# module and the dependency graph stays a DAG — the same reason paintbot keeps
# its state records in sim_types.nim.
# ---------------------------------------------------------------------------

type
  Depot* = object
    id*: string
    node*: int
    alias*: string
    colour*: string

  Scenery* = object
    kind*: string           ## "rect" | "disc"
    x*, y*, w*, h*: int     ## rect
    cx*, cy*, r*: int       ## disc
    art*: string

  CitySpec* = object
    name*: string
    gridCols*, gridRows*: int
    nodeSpacingPx*: int
    marginPx*: int
    laneCells*: int
    cellPx*: int
    laneOffsetPx*: int
    arterialCols*: seq[int]
    arterialRows*: seq[int]
    districtCols*, districtRows*: int
    districtNames*: seq[string]
    depots*: seq[Depot]
    signalCycleTicks*: int
    greenNsTicks*: int
    offsetRule*: string
    scenery*: seq[Scenery]
    raw*: JsonNode          ## pinned verbatim into every replay

  SimSnapshot* = object
    ## Everything a backward seek has to restore. Kept in memory only; a
    ## snapshot is NEVER written to the replay.
    tick*: int
    turn*: int
    rng*: Pcg32
    vehicles*: seq[Vehicle]
    cells*: seq[int]
    q*: seq[int]
    backlog*: array[Seats, seq[Parcel]]
    delivered*: array[Seats, int]
    deliveredAtTurnStart*: array[Seats, int]
    ordersCreated*: array[Seats, int]
    nextParcelId*: int
    destCursor*: int
    plans*: array[Seats, RoutingPlan]
    noise*: seq[int]
    replanQueue*: seq[int]
    eventCount*: int
    planCount*: int
    keyframeCount*: int

  Sim* = object
    config*: GameConfig
    city*: CitySpec
    tick*: int
    turn*: int
    rng*: Pcg32

    seatDepot*: array[Seats, int]     ## seat slot -> depot index
    depotSeat*: array[Seats, int]     ## depot index -> seat slot
    names*: array[Seats, string]      ## real policy names, SPECTATOR side only
    policyKinds*: array[Seats, string] ## "llm" | "scripted"

    vehicles*: seq[Vehicle]
    cells*: seq[int]                  ## lane*laneCells + cell -> vehicle or -1
    q*: seq[int]                      ## live occupancy per lane
    noise*: seq[int]                  ## per-fleet per-lane Dijkstra tie noise

    plans*: array[Seats, RoutingPlan]
    backlog*: array[Seats, seq[Parcel]]
    delivered*: array[Seats, int]
    deliveredAtTurnStart*: array[Seats, int]
    deliveredLastTurn*: array[Seats, int]
    ordersCreated*: array[Seats, int]
    tripTicks*: array[Seats, int]
    tripCount*: array[Seats, int]
    stallVehicleTicks*: array[Seats, int]
    nextParcelId*: int
    destSchedule*: seq[int]
    destCursor*: int

    replanQueue*: seq[int]
    replanHead*: int
    routeFault*: string
      ## Step 14's route guard: set by the replan step when a COMPLETED
      ## replan produced a route that does not start at the vehicle's own
      ## node, and reported by `invariantFailure`.

    moveOpp*, blockedOpp*: int
    seatMoveOpp*, seatBlockedOpp*: array[Seats, int]
    totalSeatMoveOpp*, totalSeatBlockedOpp*: array[Seats, int]
    laneOccAccum*: seq[int]
    occSamples*: int
    jamIndex*: int
    ownStallPct*: array[Seats, int]
    districtHeat*: array[DistrictCount, int]
    jamIndexSum*, jamIndexSamples*, jamIndexPeak*: int
    laneJammed*: seq[bool]
    laneJamStart*: seq[int]
    gridlockEvents*: int
    lastGridlockTick*: array[DistrictCount, int]

    events*: seq[GameEvent]
    planLog*: seq[PlanRecord]
    keyframes*: seq[Keyframe]
    vehicleBytes*: string
    snapshots*: seq[SimSnapshot]
    keepSnapshots*: bool

    turnsLlm*: array[Seats, int]
    fallbackTurns*: array[Seats, int]
    fallbackCauses*: array[Seats, array[FallbackCause, int]]

    finished*: bool
    reason*: string
    endRule*: string
    faultDetail*: string
