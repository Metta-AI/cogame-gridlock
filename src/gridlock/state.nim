## Logging, the per-tick state digest, and the event buffer.
##
## Paintbot's `gameHash` idea retargeted: one FNV-1a u32 over the whole
## mutable episode state. It goes into every keyframe and it is the
## cross-build equality check that lets the wasm viewer prove it re-derived
## the same match. A mismatch lights `#mmwarn` and playback continues
## (`mismatchQuit = false`, paintbot's default).

import std/[strutils, times]
import types

var logPrefix* = "gridlock"
var logEnabled* = true

proc logLine*(parts: varargs[string, `$`]) =
  if not logEnabled:
    return
  var line = logPrefix & ": "
  for part in parts:
    line.add(part)
  echo line

proc nowSeconds*(): float = epochTime()

const FnvOffset = 2166136261'u32
const FnvPrime = 16777619'u32

proc fnvByte(hash: var uint32, value: uint8) {.inline.} =
  hash = hash xor uint32(value)
  hash = hash * FnvPrime

proc fnvInt(hash: var uint32, value: int) {.inline.} =
  let v = uint32(value and 0xFFFF_FFFF)
  fnvByte(hash, uint8(v and 0xFF'u32))
  fnvByte(hash, uint8((v shr 8) and 0xFF'u32))
  fnvByte(hash, uint8((v shr 16) and 0xFF'u32))
  fnvByte(hash, uint8((v shr 24) and 0xFF'u32))

proc fnvU64(hash: var uint32, value: uint64) {.inline.} =
  var v = value
  for _ in 0 ..< 8:
    fnvByte(hash, uint8(v and 0xFF'u64))
    v = v shr 8

proc gridlockStateDigest*(sim: Sim): uint32 =
  var hash = FnvOffset
  fnvInt(hash, sim.tick)
  for vehicle in sim.vehicles:
    fnvInt(hash, vehicle.lane)
    fnvInt(hash, vehicle.cell)
    fnvInt(hash, ord(vehicle.state))
    fnvInt(hash, vehicle.target)
    fnvInt(hash, vehicle.parcelId)
  for occupancy in sim.q:
    fnvInt(hash, occupancy)
  for seat in 0 ..< Seats:
    fnvInt(hash, sim.delivered[seat])
  for seat in 0 ..< Seats:
    fnvInt(hash, sim.backlog[seat].len)
  fnvU64(hash, sim.rng.state)
  fnvU64(hash, sim.rng.inc)
  hash

proc fmtSeconds*(value: float): string =
  formatFloat(value, ffDecimal, 1)
