## Gridlock player: scripted or prompt policy over one private view and
## the ordinary complete routing-plan action.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <gridlock-image> --name my-gridlock \
##     --run /bin/gridlock-player --secret-env PLAYER_PROMPT="<your strategy>"

import std/[json, options, os, strutils, unicode]
import whisky
import gridlock/[types, llm]

const
  ConnectAttempts = 40
  ConnectDelayMs = 750

when isMainModule:
  let url = strutils.strip(getEnv("COWORLD_PLAYER_WS_URL"))
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  let rawPrompt = getEnv("PLAYER_PROMPT")
  let prompt =
    if rawPrompt.runeLen > 4000: rawPrompt.runeSubStr(0, 4000)
    else: rawPrompt
  let kind =
    if prompt.strip().len > 0: "prompt"
    else: "scripted"
  let scripted =
    if strutils.strip(getEnv("PLAYER_SCRIPTED")).len > 0:
      strutils.strip(getEnv("PLAYER_SCRIPTED"))
    elif kind == "scripted":
      "dispatcher"
    else:
      ""
  let label = strutils.strip(getEnv("PLAYER_POLICY_LABEL"))
  let client =
    if kind == "prompt":
      newLlmClient(parseInt(getEnv("PLAYER_MAX_OUTPUT_TOKENS", "900")),
        getEnv("PLAYER_MODEL", "claude-haiku-4-5"))
    else:
      nil

  let frame = $ %*{
    "type": "register",
    "kind": kind,
    "scripted": (if scripted.len > 0: %scripted else: newJNull()),
    "policy": (if label.len > 0: label
               elif scripted.len > 0: "scripted:" & scripted
               else: kind)}

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
    echo "gridlock player: registered ", kind,
      (if scripted.len > 0: ", scripted " & scripted else: "")
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
          ## Nothing to send: the register frame went out on connect and
          ## `applyRegistration` is idempotent, so a second copy would only
          ## be a second frame the protocol does not describe.
          echo "gridlock player: seated at slot ", payload{"slot"}.getInt(),
            " as ", payload{"fleet"}.getStr()
        of "turn":
          discard
        of "decision":
          if kind == "scripted":
            continue
          if payload["protocol"].getStr() != PlayerProtocol:
            raise newException(GridlockError,
              "unexpected player protocol")
          var reply = %*{
            "type": "action",
            "protocol": PlayerProtocol,
            "id": payload["id"],
            "source": "llm"
          }
          let timeoutSeconds = max(1,
            payload["timeout_ms"].getInt() div 1000 - 1)
          if client.disabled:
            reply["source"] = %"fallback"
            reply["cause"] = %"no_credentials"
          else:
            try:
              reply["plan"] =
                choosePromptPlan(client, prompt, $payload["view"],
                  payload["attempt"].getInt() > 1, timeoutSeconds)
            except CatchableError as error:
              echo "gridlock player: policy call failed: ", error.msg
              reply["source"] = %"fallback"
              reply["cause"] = %"transport_error"
          socket.send($reply)
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
