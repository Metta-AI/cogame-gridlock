## Gridlock player: a policy is just a prompt.
##
## Connects to the game, sends ONE register frame carrying its strategy text
## (or its scripted baseline name), then only receives until the final frame.
## Every decision is made in the game server, which sends this seat's prompt
## to the model once every routing turn.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <gridlock-image> --name my-gridlock \
##     --run /bin/gridlock-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils]
import whisky

const DefaultPrompt = """
Read jam_index before you look at your own numbers. Keep the city moving:
raise congestion_weight as the index climbs and cut dispatch once it is over
45, because a van parked at your depot costs you nothing while a van stalled
in a queue costs you the delivery AND blocks the road you need next turn.
Avoid the single worst district when its digit is 8 or 9 and it does not hold
your depot. Prefer near parcels; switch to far for one turn when your backlog
is over 50. Do not thrash — a plan you keep for three turns beats three
clever plans.
"""

const
  ConnectAttempts = 40
  ConnectDelayMs = 750

when isMainModule:
  let url = strutils.strip(getEnv("COWORLD_PLAYER_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let scripted = strutils.strip(getEnv("PLAYER_SCRIPTED"))
  var prompt = getEnv("PLAYER_PROMPT")
  if strutils.strip(prompt).len == 0 and scripted.len == 0:
    prompt = DefaultPrompt
  let label = strutils.strip(getEnv("PLAYER_POLICY_LABEL"))

  let frame = $ %*{
    "type": "register",
    "prompt": prompt,
    "scripted": (if scripted.len > 0: %scripted else: newJNull()),
    "policy": (if label.len > 0: label
               elif scripted.len > 0: "scripted:" & scripted
               else: "prompt")}

  ## Bounded connect retry: the game container and the player containers are
  ## started together, so the first few dials legitimately fail.
  var socket: WebSocket
  var connected = false
  for attempt in 1 .. ConnectAttempts:
    try:
      socket = newWebSocket(url)
      connected = true
      break
    except CatchableError as error:
      if attempt == ConnectAttempts:
        echo "gridlock player: game unreachable after ", attempt,
          " attempts (", error.msg, "); exiting cleanly"
      else:
        sleep(ConnectDelayMs)
  if not connected:
    quit(0)

  try:
    socket.send(frame)
    echo "gridlock player: registered (", prompt.len, " prompt chars",
      (if scripted.len > 0: ", scripted " & scripted else: ""), ")"
  except CatchableError as error:
    echo "gridlock player: register failed (", error.msg, "); exiting cleanly"
    quit(0)

  ## whisky's receiveMessage RAISES on a close frame or a truncated read (only
  ## a timeout returns none), and mummy's send only queues — the game's
  ## quit(0) can outrun the flushed done frame. Exit 0 on a dead socket.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "gridlock player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        if payload{"done"}.getBool(false):
          let scores = payload{"result", "scores"}
          echo "gridlock player: final scores ",
            (if scores == nil: "(none)" else: $scores)
          break
        case payload{"type"}.getStr()
        of "welcome":
          echo "gridlock player: seated at slot ", payload{"slot"}.getInt(),
            " as ", payload{"fleet"}.getStr()
          socket.send(frame)
        of "turn":
          discard
        else:
          discard
      except CatchableError as error:
        echo "gridlock player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "gridlock player: socket closed (", error.msg, "); exiting cleanly"
  try:
    socket.close()
  except CatchableError:
    discard
  quit(0)
