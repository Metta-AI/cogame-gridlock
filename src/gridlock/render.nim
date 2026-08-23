## The broadcast layer: what the viewer and the live `/global` spectator
## stream are handed.
##
## Split of responsibilities (paintbot's, kept): the WASM module owns the
## world state and hands the shell one packet per frame; the DOM chrome draws
## the scorebug, fleet counters, plan chips, event feed, jam gauge, transport
## and warnings. DOM text is set with textContent only — names are
## player-controlled data.
##
## Two payloads:
##   metaJson   once, at load: the city geometry, the lane table, the depots,
##              the real player names, the aliases and colours, the results.
##   frameJson  once per drawn frame: the tick, per-lane occupancy (the heat
##              map), every van's (lane, cell, state), the four counters, the
##              four current plans, and the events since the last frame.

import std/json
import types
import graph
import plan
import events
import sim

proc laneTableJson*(spec: CitySpec): JsonNode =
  result = newJArray()
  for id in 0 ..< LaneCount:
    let lane = laneOf(id)
    result.add(%*{
      "a": [nodePixelX(lane.tail), nodePixelY(lane.tail)],
      "b": [nodePixelX(lane.head), nodePixelY(lane.head)],
      "art": lane.arterial,
      "ns": lane.axisNs})

proc metaJson*(game: Sim, results: JsonNode): JsonNode =
  var players = newJArray()
  var aliases = newJArray()
  var colours = newJArray()
  var depots = newJArray()
  var kinds = newJArray()
  for seat in 0 ..< Seats:
    let depot = game.seatDepot[seat]
    players.add(%game.names[seat])
    aliases.add(%FleetAliases[depot])
    colours.add(%FleetColours[depot])
    kinds.add(%game.policyKinds[seat])
    depots.add(%*{
      "node": [DepotNodes[depot][0], DepotNodes[depot][1]],
      "px": [nodePixelX(depotNode(depot)), nodePixelY(depotNode(depot))],
      "alias": FleetAliases[depot],
      "colour": FleetColours[depot]})
  var scenery = newJArray()
  for piece in game.city.scenery:
    scenery.add(%*{
      "kind": piece.kind,
      "x": piece.x, "y": piece.y, "w": piece.w, "h": piece.h,
      "cx": piece.cx, "cy": piece.cy, "r": piece.r,
      "art": piece.art})
  var districtNames = newJArray()
  for name in DistrictNameTable:
    districtNames.add(%name)
  %*{
    "type": "meta",
    "game": "gridlock",
    "protocol": ReplayProtocol,
    "board": [MapWidth, MapHeight],
    "grid": [GridCols, GridRows],
    "spacing": NodeSpacingPx,
    "margin": MarginPx,
    "lane_cells": game.config.laneCells,
    "cell_px": game.config.cellPx,
    "lane_offset": game.city.laneOffsetPx,
    "ticks_per_second": TargetFps,
    "playback_speeds": PlaybackSpeeds,
    "tick_count": game.config.episodeTicks,
    "turn_ticks": game.config.turnTicks,
    "vans_per_fleet": game.config.fleetSize,
    "lanes": laneTableJson(game.city),
    "depots": depots,
    "players": players,
    "aliases": aliases,
    "colours": colours,
    "policy_kinds": kinds,
    "district_names": districtNames,
    "scenery": scenery,
    "results": results}

proc frameJson*(game: Sim, eventFrom: int): JsonNode =
  var occupancy = newJArray()
  for lane in 0 ..< LaneCount:
    occupancy.add(%game.q[lane])
  var vans = newJArray()
  for g in 0 ..< game.vehicles.len:
    let lane =
      if game.vehicles[g].lane < 0: DockedSentinel else: game.vehicles[g].lane
    vans.add(%lane)
    vans.add(%game.vehicles[g].cell)
    vans.add(%ord(game.vehicles[g].state))
  var delivered = newJArray()
  var onRoad = newJArray()
  var backlog = newJArray()
  var plans = newJArray()
  for seat in 0 ..< Seats:
    delivered.add(%game.delivered[seat])
    onRoad.add(%onRoadCount(game, seat))
    backlog.add(%game.backlog[seat].len)
    var entry = planJson(game.plans[seat])
    entry["source"] = %($game.plans[seat].source)
    plans.add(entry)
  var digits = newJArray()
  for d in 0 ..< DistrictCount:
    digits.add(%game.districtHeat[d])
  var recent = newJArray()
  for i in max(0, eventFrom) ..< game.events.len:
    recent.add(jsonRow(game.events[i]))
  %*{
    "type": "frame",
    "t": game.tick,
    "turn": game.turn,
    "jam": game.jamIndex,
    "digits": digits,
    "delivered": delivered,
    "on_road": onRoad,
    "backlog": backlog,
    "q": occupancy,
    "v": vans,
    "plans": plans,
    "events": recent,
    "event_cursor": game.events.len}
