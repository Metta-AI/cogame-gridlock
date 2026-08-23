## The viewer: the emscripten/JS pairing assertion that would have caught the
## lantern deadlock, the load signalling the smoke depends on, and the chrome
## ids and CSS the 360 px composition rests on.
##
## The browser half is `tools/ci/viewer_smoke.mjs`, run by ci.yml's
## `wasm-viewer` job against the replay this repo's own game just produced.
## What this file pins is everything a static read can prove — and, when a
## bundle happens to be present, the native harness over the emitted module.

import std/[os, osproc, strutils, unittest]
import support/helpers

## Comments are stripped before the pairing assertions: this file's own
## comment block NAMES the flags it forbids.
let configNims = stripComments(readSource("replay-viewer/config.nims"))
let worker = readSource("replay-viewer/static_replay_worker.js")
let shell = readSource("replay-viewer/static_replay.js")
let page = readSource("client/replay_broadcast.html")
let core = readSource("client/broadcast_core.js")
let chrome = readSource("client/chrome_common.js")

const InheritedChromeIds = [
  "viewport", "stage", "board", "lightpool", "grain", "chrome", "scorebug",
  "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
  "ffwd-mini", "viewpanel", "minimap", "minimap-canvas", "zoombar",
  "zoom-out", "zoom-slider", "zoom-in", "zoom-read", "mmwarn", "bannerlane",
  "killfeed", "transport", "btn-restart", "btn-back", "btn-play", "btn-fwd",
  "btn-end", "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip",
  "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill", "lulls",
  "scrub-win", "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how",
  "ec-teams", "ec-replay", "status", "lockerroom", "lk-art", "lk-bg",
  "lk-sprites", "lk-cap"]

const AddedChromeIds = ["fleetbug", "planbar", "jamgauge", "jamflash"]

suite "the emscripten / JS pairing":
  test "config.nims carries NEITHER MODULARIZE nor EXPORT_NAME":
    ## cogame-lantern, 2026-08-23: MODULARIZE/EXPORT_NAME link flags copied
    ## from a babel-lineage starter against a paintbot-lineage bootstrap that
    ## waits for onRuntimeInitialized. Nothing throws, nothing logs, and the
    ## page hangs on "Loading replay..." forever with every asset at 200.
    check not configNims.contains("MODULARIZE")
    check not configNims.contains("EXPORT_NAME")

  test "nothing calls into the module before main() has run":
    ## Emscripten fires onRuntimeInitialized BEFORE callMain(), and Nim
    ## initialises every module-level global (the 288-lane road table among
    ## them) inside main. An export called first reads an EMPTY graph: no
    ## route resolves, no van is dispatched, and the viewer replays a frozen
    ## city that fails the first keyframe digest check. Both drivers defer.
    let index = worker.find("Module.onRuntimeInitialized = function")
    check index > 0
    let branch = worker[index ..< min(worker.len, index + 900)]
    check branch.contains("setTimeout(")
    let harness = readSource("tools/wasm_replay_smoke.cjs")
    check harness.contains("onRuntimeInitialized: () => setTimeout(run, 0)")

  test "the worker still uses onRuntimeInitialized and importScripts":
    check worker.contains("Module.onRuntimeInitialized")
    check worker.contains("importScripts(")
    check worker.contains("./gridlock_replay.js")
    check worker.contains("./broadcast_core.js")
    check worker.contains("./wire_constants.js")
    ## And it never calls a factory.
    check not worker.contains("GridlockReplayModule(")

  test "the link flags export exactly the entry points the worker calls":
    for symbol in ["_gridlock_load_replay", "_gridlock_frame",
        "_gridlock_input", "_gridlock_packet_ptr", "_gridlock_packet_len",
        "_gridlock_mismatch_tick", "_gridlock_error_ptr",
        "_gridlock_error_len", "_gridlock_stage_ptr", "_gridlock_stage_len",
        "_main", "_malloc", "_free"]:
      check configNims.contains(symbol)
    for called in ["_gridlock_load_replay", "_gridlock_frame",
        "_gridlock_input", "_gridlock_packet_ptr", "_gridlock_packet_len",
        "_gridlock_mismatch_tick", "_gridlock_error_ptr",
        "_gridlock_error_len", "_gridlock_stage_ptr", "_gridlock_stage_len",
        "_malloc", "_free"]:
      check worker.contains("Module." & called)
    check configNims.contains("ENVIRONMENT=web,worker,node")
    check configNims.contains("ABORTING_MALLOC=1")
    check configNims.contains("ALLOW_MEMORY_GROWTH")
    check configNims.contains("EXPORTED_RUNTIME_METHODS=HEAPU8")
    check configNims.contains("--mm:arc")
    check configNims.contains("--exceptions:goto")
    check configNims.contains("--define:useMalloc")
    check configNims.contains("threads\", \"off")

  test "the wasm entry exports every symbol the link flags name":
    let entry = readSource("replay-viewer/gridlock_replay.nim")
    for symbol in ["gridlock_load_replay", "gridlock_frame", "gridlock_input",
        "gridlock_packet_ptr", "gridlock_packet_len",
        "gridlock_mismatch_tick", "gridlock_error_ptr", "gridlock_error_len",
        "gridlock_stage_ptr", "gridlock_stage_len"]:
      check entry.contains("exportc: \"" & symbol & "\"")
    check entry.contains("emscripten_exit_with_live_runtime")
    check entry.contains("stampStage")

suite "load signalling":
  test "data-replay-loaded is set in the firstFrame branch":
    let index = shell.find("message.type === 'firstFrame'")
    check index > 0
    let branch = shell[index ..< min(shell.len, index + 400)]
    check branch.contains("markLoaded()")
    check shell.contains(
      "document.documentElement.setAttribute('data-replay-loaded', 'true')")

  test "data-replay-error is set in showFailure":
    let index = shell.find("function showFailure")
    check index > 0
    let stop = shell.find("function setMismatchTick", index)
    check stop > index
    let body = shell[index ..< stop]
    check body.contains("data-replay-error")
    check body.contains("tell('error'")

  test "the coworld-replay bridge posts loading, ready and error":
    check shell.contains("src: 'coworld-replay'")
    check shell.contains("tell('loading')")
    check shell.contains("tell('ready')")
    check shell.contains("tell('error'")
    check shell.contains("window.parent === window")
    ## ready fires inside a double requestAnimationFrame after a drawn frame.
    let index = shell.find("function markLoaded")
    check index > 0
    let body = shell[index ..< min(shell.len, index + 600)]
    check body.count("requestAnimationFrame") >= 2

  test "the replay fetch is bounded and offers a retry":
    check shell.contains("FETCH_TIMEOUT_MS")
    check worker.contains("AbortController")
    check shell.contains("Retry")

  test "the mismatch tick surfaces as an attribute the chrome reads":
    check shell.contains("data-replay-mismatch-tick")
    check page.contains("data-replay-mismatch-tick")
    check page.contains("mmwarn")

suite "chrome":
  test "every inherited chrome id is still there":
    for id in InheritedChromeIds:
      check page.contains("id=\"" & id & "\"")

  test "the added gridlock ids are there and the CTF ones are gone":
    for id in AddedChromeIds:
      check page.contains("id=\"" & id & "\"")
    for id in ["fpv", "flagicon", "lives", "squadpips", "killicon"]:
      check not page.contains("id=\"" & id & "\"")

  test "the transport buttons do what the transport says they do":
    ## Readout 8 lists play/pause, back one tick, +5 s, jump to end. `#btn-back`
    ## used to seek 0 (which is `#btn-restart`'s job) and `#btn-fwd` used to
    ## set 16x, so two labelled controls lied about what they did.
    let back = chrome.find("el('btn-back')")
    check back > 0
    let backBody = chrome[back ..< min(chrome.len, back + 200)]
    check backBody.contains("core.seek(Math.max(0, lastTick - 1))")
    let fwd = chrome.find("el('btn-fwd')")
    check fwd > back
    let fwdBody = chrome[fwd ..< min(chrome.len, fwd + 320)]
    check fwdBody.contains("5 * (meta.ticks_per_second || 24)")
    check fwdBody.contains("core.seek(")
    check not fwdBody.contains("setSpeed(16)")
    ## And the frame stream is where the current tick comes from.
    check chrome.contains("lastTick = payload.t || 0")

  test "the scorebug survives 360 px":
    ## Playbook gotcha: the embedded featured-match iframe is ~360 px wide and
    ## player names collapsed to ellipses.
    check page.contains(".plate .team-name")
    check page.contains(".plate-name")
    check page.contains("flex:1 1 auto")
    check page.contains("min-width:3.2em")
    check page.contains("text-overflow:ellipsis")
    check page.contains("@media (max-width: 640px)")
    let index = page.find("@media (max-width: 640px)")
    let narrow = page[index ..< min(page.len, index + 900)]
    check narrow.contains("#planbar{display:none}")
    check narrow.contains("#viewpanel{display:none}")
    check narrow.contains(".chiplabel{display:none}")
    check page.contains("--hudscale")
    check page.contains("--u:")
    check page.contains(".tiny ")

  test "the relayout loop drives --hudscale from the board width":
    check chrome.contains("--hudscale")
    check chrome.contains("classList.toggle('tiny'")
    check chrome.contains("window.ChromeCommon") or
      chrome.contains("globalScope.ChromeCommon")

  test "DOM text is set with textContent, never innerHTML":
    check not chrome.contains(".innerHTML")
    check not shell.contains(".innerHTML")

  test "the world renderer draws the congestion heat ramp under the vans":
    let lanes = core.find("function drawLanes")
    let vans = core.find("function drawVans")
    check lanes > 0
    check vans > lanes
    check core.contains("HEAT")
    check core.contains("drawIntersections")
    check core.contains("drawDepots")
    check core.contains("drawScenery")

  test "the bundle's art list is what the build hook copies":
    for asset in ["asphalt.jpg", "intersection.png", "block_park.png",
        "plaza.png", "depot_copper.png", "depot_cobalt.png",
        "depot_verde.png", "depot_saffron.png", "van.png", "van_loaded.png",
        "parcel_pin.png"]:
      check fileExists("client/art/" & asset)
      check core.contains(asset)
    check fileExists("data/font.ttf")
    check fileExists("client/art/walls/wall_h.jpg")
    check fileExists("client/art/walls/wall_v.jpg")

suite "the native half of the viewer check":
  ## The emitted module is only present after tools/build_replay_viewer.sh has
  ## run, which needs emsdk. When it is there, drive it exactly as the browser
  ## does; when it is not, the browser half in ci.yml is the gate.
  test "the emitted module replays to the end when a bundle is present":
    let bundle = "dist/static-replay-viewer"
    if not fileExists(bundle / "gridlock_replay.js"):
      echo "no built bundle in " & bundle & "; ci.yml's wasm-viewer job is " &
        "the gate for the browser half"
      skip()
    else:
      let harness = "tools/wasm_replay_smoke.cjs"
      check fileExists(harness)
      var game = newTestSim(480, 3)
      runScripted(game, allKinds(skDispatcher))
      let path = getTempDir() / "gridlock-viewer-smoke.replay"
      writeFile(path, replayBytes(game, resultsJson(game)))
      let outcome = execCmdEx("node " & harness & " " & bundle & " " & path)
      if outcome.exitCode != 0:
        echo outcome.output
      check outcome.exitCode == 0
