## The authored city: loads `data/<cityPath>.cityspec.json`, validates every
## derived constant, and keeps the raw JSON so it can be pinned verbatim into
## every replay (exactly as paintbot pins `mapSpec`).
##
## Gridlock ships ONE city. Paintbot's procedural generator, validators, map
## pool, style knobs, editor and mapkit are all dropped: a road network whose
## four depots are exactly interchangeable is not something a seeded draw
## gives you. City variety is a v0.2 feature.

import std/[json, os, strutils]
import types

proc jarr(node: JsonNode): JsonNode =
  ## An always-iterable array view of a possibly missing key.
  if node == nil or node.kind != JArray: newJArray() else: node

proc parseCitySpec*(raw: JsonNode): CitySpec =
  if raw.kind != JObject:
    raise newException(GridlockError, "cityspec must be a JSON object")
  result.raw = raw
  result.name = raw{"name"}.getStr("gridcity")
  let grid = raw{"grid"}
  result.gridCols = if grid != nil and grid.len > 0: grid[0].getInt() else: GridCols
  result.gridRows = if grid != nil and grid.len > 1: grid[1].getInt() else: GridRows
  result.nodeSpacingPx = raw{"node_spacing_px"}.getInt(NodeSpacingPx)
  result.marginPx = raw{"margin_px"}.getInt(MarginPx)
  result.laneCells = raw{"lane_cells"}.getInt(LaneCellsDefault)
  result.cellPx = raw{"cell_px"}.getInt(CellPxDefault)
  result.laneOffsetPx = raw{"lane_offset_px"}.getInt(LaneOffsetPx)
  for v in jarr(raw{"arterial_cols"}):
    result.arterialCols.add(v.getInt())
  for v in jarr(raw{"arterial_rows"}):
    result.arterialRows.add(v.getInt())
  let districts = raw{"districts"}
  result.districtCols =
    if districts != nil and districts.len > 0: districts[0].getInt()
    else: DistrictCols
  result.districtRows =
    if districts != nil and districts.len > 1: districts[1].getInt()
    else: DistrictRows
  let names = raw{"district_names"}
  if names != nil and names.kind == JArray:
    for row in names:
      for cell in jarr(row):
        result.districtNames.add(cell.getStr())
  for entry in jarr(raw{"depots"}):
    let node = entry{"node"}
    result.depots.add(Depot(
      id: entry{"id"}.getStr(),
      node: nodeIndex(node[0].getInt(), node[1].getInt()),
      alias: entry{"alias"}.getStr(),
      colour: entry{"colour"}.getStr()))
  let signal = raw{"signal"}
  if signal != nil and signal.kind == JObject:
    result.signalCycleTicks = signal{"cycle_ticks"}.getInt(96)
    result.greenNsTicks = signal{"green_ns_ticks"}.getInt(48)
    result.offsetRule = signal{"offset_rule"}.getStr("((ix + iy) mod 4) * 24")
  else:
    result.signalCycleTicks = 96
    result.greenNsTicks = 48
    result.offsetRule = "((ix + iy) mod 4) * 24"
  for entry in jarr(raw{"scenery"}):
    var piece = Scenery(kind: entry{"kind"}.getStr("rect"),
      art: entry{"art"}.getStr())
    piece.x = entry{"x"}.getInt()
    piece.y = entry{"y"}.getInt()
    piece.w = entry{"w"}.getInt()
    piece.h = entry{"h"}.getInt()
    piece.cx = entry{"cx"}.getInt()
    piece.cy = entry{"cy"}.getInt()
    piece.r = entry{"r"}.getInt()
    result.scenery.add(piece)

proc validateCitySpec*(spec: CitySpec) =
  if spec.gridCols != GridCols or spec.gridRows != GridRows:
    raise newException(GridlockError, "gridlock v1 is a 9x9 city")
  if spec.nodeSpacingPx != spec.laneCells * spec.cellPx:
    raise newException(GridlockError,
      "node spacing must equal lane_cells * cell_px")
  if spec.districtCols != DistrictCols or spec.districtRows != DistrictRows:
    raise newException(GridlockError, "gridlock v1 has a 3x3 district grid")
  if spec.depots.len != Seats:
    raise newException(GridlockError, "gridlock v1 needs exactly four depots")
  if spec.districtNames.len != DistrictCount:
    raise newException(GridlockError, "district_names must name nine districts")
  for i, depot in spec.depots:
    if depot.node != depotNode(i):
      raise newException(GridlockError,
        "depot " & depot.id & " is not on the mirror orbit of (1,1)")
    if depot.alias != FleetAliases[i]:
      raise newException(GridlockError, "depot alias mismatch: " & depot.alias)
  if spec.marginPx * 2 + spec.nodeSpacingPx * (GridCols - 1) != MapWidth:
    raise newException(GridlockError, "board must be 1024 px wide")

proc cityDataDir*(): string =
  let appDir = getAppDir()
  for candidate in [appDir / "data", appDir / ".." / "data", "data",
      ".." / "data"]:
    if dirExists(candidate):
      return candidate
  "data"

proc loadCitySpec*(cityPath: string): CitySpec =
  ## `cityPath` is a bare name ("gridcity"); the file is
  ## `<data>/<name>.cityspec.json`.
  let name =
    if cityPath.strip().len == 0: "gridcity" else: cityPath.strip()
  let path = cityDataDir() / (name & ".cityspec.json")
  if not fileExists(path):
    raise newException(GridlockError, "city spec not found: " & path)
  result = parseCitySpec(parseJson(readFile(path)))
  validateCitySpec(result)

proc mirroredScenery*(spec: CitySpec): bool =
  ## The scenery list is decoration only, but it must be invariant under both
  ## mirror axes or the four fleets do not see the same city.
  proc key(p: Scenery): string =
    if p.kind == "disc": "d:" & $p.cx & "," & $p.cy & "," & $p.r
    else: "r:" & $p.x & "," & $p.y & "," & $p.w & "," & $p.h
  var keys: seq[string]
  for piece in spec.scenery:
    keys.add(key(piece))
  proc mirrorX(p: Scenery): Scenery =
    result = p
    if p.kind == "disc": result.cx = MapWidth - p.cx
    else: result.x = MapWidth - p.x - p.w
  proc mirrorY(p: Scenery): Scenery =
    result = p
    if p.kind == "disc": result.cy = MapHeight - p.cy
    else: result.y = MapHeight - p.y - p.h
  for piece in spec.scenery:
    if key(mirrorX(piece)) notin keys: return false
    if key(mirrorY(piece)) notin keys: return false
    if key(mirrorY(mirrorX(piece))) notin keys: return false
  true
