## Validate a saved production replay against the actual deterministic simulator.
import std/[base64, json, os]
import gridlock/[replay, sim]

let args = commandLineParams()
doAssert args.len == 1
let document = parseFile(args[0])
let data = parseReplayBytes($document)
let actual = rederive(data)
doAssert actual.tick == data.tickCount
doAssert actual.vehicleBytes == decode(document["vehicles_b64"].getStr())
doAssert actual.keyframes.len == data.keyframes.len
for index in 0 ..< data.keyframes.len:
  doAssert actual.keyframes[index].t == data.keyframes[index].t
  doAssert actual.keyframes[index].d == data.keyframes[index].d
for seat in 0 ..< Seats:
  doAssert actual.delivered[seat] == document["results"]["delivered"][seat].getInt()
echo "verified ", actual.tick, " ticks and ", actual.keyframes.len, " keyframes"
