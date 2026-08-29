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
## The page script is everything after the last <script> tag: the shared
## chrome (chrome_common.js) is the starter's file verbatim, so the page's
## own logic is what the chrome cases below grep.
let pageScript = page[page.rfind("<script>") ..< page.len]

const InheritedChromeIds = [
  "viewport", "stage", "board", "lightpool", "grain", "chrome", "scorebug",
  "plates-l", "plates-r", "clock", "clock-time", "clock-caption",
  "ffwd-mini", "mmwarn", "bannerlane",
  "killfeed", "transport", "btn-restart", "btn-back", "btn-play", "btn-fwd",
  "btn-end", "btn-loop", "btn-skip", "btn-spoilers", "ffwd-chip", "win-chip",
  "tick-clock", "speedchips", "scrub", "momentum", "scrub-fill", "lulls",
  "scrub-win", "scrub-head", "endcard", "ec-headline", "ec-wincond", "ec-how",
  "ec-teams", "ec-replay", "status", "lockerroom", "lk-art", "lk-bg",
  "lk-sprites", "lk-cap"]

const AddedChromeIds = ["fleetbug", "planbar", "jamgauge", "jamflash"]

## Starter signatures the page must carry: the locker-room curtain, the
## scrubber track + momentum graph + beat markers, the lull-skip chip, the
## verdict chip, the endcard fade, the --hudscale / --band reserve loop and
## the event lane. A page that only shares the starter's ids is not a port.
const StarterSignatures = [
  "#lockerroom", ".scrub-track", ".momentum-label", ".beat-marker",
  "#ffwd-chip", ".win-chip", "@keyframes cardfade", "--hudscale", "--band",
  "#ev-lane"]

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

suite "provenance":
  test "chrome_common.js is the starter's file, byte for byte":
    ## The shared chrome is copied, not rewritten: the committed reference
    ## copy is hive's client/chrome_common.js (the starter's plus the
    ## clickable, labelled beat-marker patch, plus the fleet-wide replay
    ## transport patch: the 0.5x speed chip and its '5' command).
    let reference = readSource("tests/fixtures/chrome_common.starter.js")
    check chrome == reference
    check chrome.contains("window.ChromeCommon = function (ctx)")
    check chrome.contains("function markBeat(tick, kind, team, label)")

  test "the page carries the starter's chrome, not only its ids":
    for signature in StarterSignatures:
      check page.contains(signature)
    ## The endcard covers the board region only and stops above the
    ## transport band, so the scrubber stays clickable under it.
    let card = page.find("#endcard {")
    check card > 0
    let cardBody = page[card ..< min(page.len, card + 900)]
    check cardBody.contains("bottom: var(--band, 0px)")
    check cardBody.contains("top: var(--topband, 0px)")
    check not page.contains("#endcard{position:absolute;inset:0")
    check page.contains("#endcard.on { display: flex;")
    ## The kill feed rides above the transport band.
    check page.contains("bottom: calc(var(--band, 0px) + 40 * var(--u))")
    ## And the three splice markers sit where raid has them, in order.
    let wire = page.find("<!-- WIRE_CONSTANTS -->")
    let common = page.find("<!-- CHROME_COMMON -->")
    let broadcast = page.find("<!-- BROADCAST_CORE -->")
    check wire > 0 and common > wire and broadcast > common
    check page.find("</body>") > broadcast

  test "the page boots the worker core the way the shell emits it":
    check pageScript.contains("window.GridlockStaticReplay.createCore({")
    for callback in ["onText:", "onStatus:", "onFirstFrame:"]:
      check pageScript.contains(callback)
    check pageScript.contains("payload.type === 'meta'")
    ## The beats, lulls and momentum curves are built up front from
    ## meta.events, which the worker splices off the fetched replay.
    check pageScript.contains("meta.events")
    check worker.contains("function withReplayEvents")
    check worker.contains("replayEvents = readReplayEvents(bytes)")
    check pageScript.contains("C.markBeat(e.t, 'gridlock'")
    check pageScript.contains("C.markBeat(e.t, 'jam'")
    check pageScript.contains("C.ingestLullSpans(state)")
    check pageScript.contains("C.ingestLeadSeries(state)")
    check pageScript.contains("C.setVerdict({ winner: TEAMS[results.winner]")
    check page.contains(".beat-marker.gridlock")
    check page.contains(".beat-marker.jam")

suite "chrome":
  test "every inherited chrome id is still there":
    for id in InheritedChromeIds:
      check page.contains("id=\"" & id & "\"")

  test "the added gridlock ids are there and the CTF ones are gone":
    for id in AddedChromeIds:
      check page.contains("id=\"" & id & "\"")
    for id in ["fpv", "flagicon", "lives", "squadpips", "killicon"]:
      check not page.contains("id=\"" & id & "\"")
    ## The city fits the frame: the starter's zoom bar + minimap are dropped,
    ## not hidden, and nothing wires the zoom API.
    for id in ["viewpanel", "minimap", "minimap-canvas", "zoombar", "zoom-out",
               "zoom-slider", "zoom-in", "zoom-read"]:
      check not page.contains("id=\"" & id & "\"")
    check not pageScript.contains("core.zoomAt")
    check not pageScript.contains("core.attachMinimap")

  test "the 1/2x replay speed reaches every layer":
    ## The fleet-wide half speed: the chrome's chip map sends command '5'
    ## (and its file:// fallback speed list leads with 0.5), the page maps
    ## '5' to sp 0.5, and the shell's playhead stretches the tick interval —
    ## one sim tick every OTHER display frame — instead of splitting a tick.
    check chrome.contains("0.5: '5'")
    check chrome.contains("[0.5, 1, 2, 3, 4, 8, 16]")
    check pageScript.contains("case '5': state.sp = 0.5; break;")
    check shell.contains("speed < 1 ? frameMs / speed : frameMs")
    check shell.contains("Math.max(0.5, value || 1)")

  test "a gridlock event drives #jamflash, not only the canvas":
    ## The district rectangle is drawn on the board canvas because only the
    ## canvas carries the pan/zoom transform; the element the readout is named
    ## for carries the full-frame pulse, off the same event.
    check pageScript.contains("$('jamflash')")
    check pageScript.contains("flash.classList.add('show')")
    check pageScript.contains("flash.classList.remove('show')")
    check page.contains("#jamflash.show{opacity:1}")
    check core.contains("function drawFlash")

  test "the transport buttons do what the transport says they do":
    ## Readout 8 lists play/pause, back one tick, +5 s, jump to end. `#btn-back`
    ## used to seek 0 (which is `#btn-restart`'s job) and `#btn-fwd` used to
    ## set 16x, so two labelled controls lied about what they did.
    let back = pageScript.find("bind('btn-back'")
    check back > 0
    let backBody = pageScript[back ..< min(pageScript.len, back + 200)]
    check backBody.contains("core.seek(Math.max(0, lastTick - 1))")
    let fwd = pageScript.find("bind('btn-fwd'")
    check fwd > back
    let fwdBody = pageScript[fwd ..< min(pageScript.len, fwd + 320)]
    check fwdBody.contains("5 * (meta.ticks_per_second || 24)")
    check fwdBody.contains("core.seek(")
    check not fwdBody.contains("setSpeed(16)")
    ## And the frame stream is where the current tick comes from.
    check pageScript.contains("lastTick = payload.t || 0")

  test "no visible transport control is a no-op":
    ## Every button in the transport row is wired: seven in the page script
    ## and the spoilers toggle inside the starter's chrome_common.js. A
    ## control a spectator can click and see nothing happen is a legibility
    ## defect, so none is hidden either.
    for id in ["btn-restart", "btn-back", "btn-play", "btn-fwd", "btn-end",
        "btn-loop", "btn-skip"]:
      check pageScript.contains("bind('" & id & "'")
    check chrome.contains("$('btn-spoilers')")
    check pageScript.contains("state.lp = !state.lp")
    check pageScript.contains("state.sk = !state.sk")
    check pageScript.contains("core.seek(0)")
    check pageScript.contains("C.setSpoilers(!C.getSpoilers())")
    check not page.contains("#btn-skip,#btn-spoilers{display:none}")
    ## Lull skipping has something to skip: the spans, the chip and the
    ## 16x burn are all present.
    check pageScript.contains("inLull(state.t)")
    check page.contains("CITY FLOWING")
    check pageScript.contains("ffwd-mini") or chrome.contains("ffwd-mini")

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
    check narrow.contains(".chiplabel{display:none}")
    check narrow.contains("#fleetbug .fleet-alias, #fleetbug .fleet-bar { display: none; }")
    check narrow.contains(".plate .team-alias { display: none; }")
    check page.contains("--hudscale")
    check page.contains("--u:")
    check page.contains(".tiny ")

  test "the relayout loop drives --hudscale and --band from the stage":
    ## --u is computed on :root from --hudscale, so the knob is set on
    ## document.documentElement (a value on #stage would never reach --u);
    ## the transport's measured height is reserved as --band the same way.
    let loop = pageScript.find("function relayout()")
    check loop > 0
    let body = pageScript[loop ..< min(pageScript.len, loop + 2200)]
    check body.contains("root.style.setProperty('--hudscale'")
    check body.contains("root.style.setProperty('--band'")
    check body.contains("stage.classList.toggle('tiny'")
    check body.contains("core.setViewportFit()")
    check chrome.contains("window.ChromeCommon")

  test "DOM text is set with textContent, never innerHTML":
    ## Player names are player-controlled data: the page's own script and
    ## the shell never touch innerHTML. (The starter's chrome_common.js
    ## builds its SVG momentum graph with innerHTML; no name reaches it.)
    check not pageScript.contains(".innerHTML")
    check not shell.contains(".innerHTML")
    check pageScript.contains("name.textContent = meta.players[seat]")

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
        "plaza.png", "depot_carbon.png", "depot_oxygen.png",
        "depot_germanium.png", "depot_silicon.png", "van.png", "van_loaded.png",
        "parcel_pin.png"]:
      check fileExists("client/art/" & asset)
      check core.contains(asset)
    check fileExists("data/font.ttf")
    check fileExists("client/art/walls/wall_h.jpg")
    check fileExists("client/art/walls/wall_v.jpg")

suite "the native half of the viewer check":
  ## The emitted module is only present after tools/build_replay_viewer.sh has
  ## run, which needs emsdk — so a developer sandbox without one gets a notice
  ## instead of a red suite. CI does NOT get that latitude: ci.yml's
  ## `viewer-native` job downloads the bundle wasm-viewer built and runs this
  ## file with GRIDLOCK_REQUIRE_BUNDLE=1, which turns a missing bundle into a
  ## failure. Without that job this case would never once have executed.
  test "the emitted module replays to the end when a bundle is present":
    let bundle = getEnv("GRIDLOCK_VIEWER_BUNDLE", "dist/static-replay-viewer")
    let required = getEnv("GRIDLOCK_REQUIRE_BUNDLE").len > 0
    if not fileExists(bundle / "gridlock_replay.js"):
      if required:
        checkpoint("GRIDLOCK_REQUIRE_BUNDLE is set and " & bundle &
          "/gridlock_replay.js is missing: the bundle this case exists to " &
          "drive was not built or not downloaded")
        fail()
      else:
        echo "no built bundle in " & bundle & "; set GRIDLOCK_REQUIRE_BUNDLE " &
          "to make this a failure (ci.yml's viewer-native job does)"
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
