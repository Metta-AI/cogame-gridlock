## The authored city: it loads, every derived constant matches the rules, the
## scenery is mirror-invariant and never sits on a road, and the four depots
## carry the documented aliases and colours.

import std/[json, os, unittest]
import support/helpers

suite "gridcity":
  setup:
    let spec = testCity()

  test "the spec loads and validates":
    check spec.name == "gridcity"
    validateCitySpec(spec)

  test "every derived constant matches the rules":
    check spec.gridCols == 9
    check spec.gridRows == 9
    check spec.nodeSpacingPx == 112
    check spec.marginPx == 64
    check spec.laneCells == 14
    check spec.cellPx == 8
    check spec.laneCells * spec.cellPx == spec.nodeSpacingPx
    check spec.marginPx * 2 + spec.nodeSpacingPx * 8 == 1024
    check spec.districtCols == 3
    check spec.districtRows == 3
    check spec.arterialCols == @[2, 4, 6]
    check spec.arterialRows == @[2, 4, 6]
    check spec.signalCycleTicks == 96
    check spec.greenNsTicks == 48

  test "the four depots carry the documented aliases and colours":
    check spec.depots.len == 4
    for i, depot in spec.depots:
      check depot.node == depotNode(i)
      check depot.alias == FleetAliases[i]
      check depot.colour == FleetColours[i]
    check spec.depots[0].alias == "Copper"
    check spec.depots[1].alias == "Cobalt"
    check spec.depots[2].alias == "Verde"
    check spec.depots[3].alias == "Saffron"

  test "district names are the documented nine":
    check spec.districtNames == @["NW", "N", "NE", "W", "CENTRE", "E",
      "SW", "S", "SE"]

  test "the scenery list is invariant under both mirrors":
    check spec.scenery.len > 0
    check mirroredScenery(spec)

  test "no scenery piece overlaps a lane cell or an intersection box":
    ## Every road corridor is +/- 10 px of a grid line (a 6 px lane offset
    ## plus a 4 px van half-width); an intersection box is 16 x 16 px.
    for piece in spec.scenery:
      var x0, y0, x1, y1: int
      if piece.kind == "disc":
        x0 = piece.cx - piece.r
        x1 = piece.cx + piece.r
        y0 = piece.cy - piece.r
        y1 = piece.cy + piece.r
      else:
        x0 = piece.x
        x1 = piece.x + piece.w
        y0 = piece.y
        y1 = piece.y + piece.h
      for i in 0 ..< 9:
        let line = spec.marginPx + spec.nodeSpacingPx * i
        check x1 < line - 10 or x0 > line + 10
        check y1 < line - 10 or y0 > line + 10

  test "the raw spec is pinned verbatim so a replay can carry it":
    check spec.raw != nil
    check spec.raw.kind == JObject
    let reparsed = parseCitySpec(spec.raw)
    validateCitySpec(reparsed)
    check reparsed.scenery.len == spec.scenery.len

  test "a missing city file is a clean error, not a crash":
    expect GridlockError:
      discard loadCitySpec("no-such-city")

  test "the generator script that produced the spec is committed":
    check fileExists("scripts/art/make_city.py")
