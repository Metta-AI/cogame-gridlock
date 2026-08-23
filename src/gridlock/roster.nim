## Join, auth, slots and tokens. Forked in shape from paintbot's
## `src/ctf/roster.nim`, minus the reward/account machinery gridlock has no
## use for.
##
## A seat that never registers, or registers with neither field, is treated as
## `scripted: "dispatcher"` — a no-show never ends the episode.

import std/[json, strutils, unicode]
import types
import baselines

type
  SeatRegistration* = object
    prompt*: string
    scripted*: ScriptKind
    policyLabel*: string
    connected*: bool
    everConnected*: bool
    registered*: bool

  Roster* = object
    tokens*: seq[string]
    seats*: array[Seats, SeatRegistration]

proc initRoster*(tokens: seq[string]): Roster =
  result.tokens = tokens
  for seat in 0 ..< Seats:
    result.seats[seat] = SeatRegistration(
      prompt: "", scripted: skNone, policyLabel: "",
      connected: false, everConnected: false, registered: false)

proc authorize*(roster: Roster, slot: int, token: string): bool =
  slot >= 0 and slot < Seats and slot < roster.tokens.len and
    roster.tokens[slot].len > 0 and roster.tokens[slot] == token

proc applyRegistration*(roster: var Roster, slot: int, payload: JsonNode) =
  ## `{"type":"register","prompt":…,"scripted":…,"policy":…}`. The prompt is
  ## truncated (never rejected) at 4000 runes and is NEVER written to the
  ## replay or the results.
  if slot < 0 or slot >= Seats:
    return
  if payload == nil or payload.kind != JObject:
    return
  if payload{"type"}.getStr("register") != "register":
    return
  var prompt = payload{"prompt"}.getStr()
  if prompt.runeLen > MaxPromptRunes:
    prompt = prompt.runeSubStr(0, MaxPromptRunes)
  let scriptedNode = payload{"scripted"}
  let scripted =
    if scriptedNode == nil or scriptedNode.kind == JNull: skNone
    elif scriptedNode.kind == JBool:
      (if scriptedNode.getBool(): skDispatcher else: skNone)
    else: parseScriptKind(scriptedNode.getStr())
  roster.seats[slot].prompt = prompt
  roster.seats[slot].scripted = scripted
  roster.seats[slot].policyLabel =
    cleanLine(payload{"policy"}.getStr(), MaxPolicyRunes)
  roster.seats[slot].registered = true

proc policyKindOf*(seat: SeatRegistration): string =
  if seat.scripted != skNone or strutils.strip(seat.prompt).len == 0:
    "scripted"
  else:
    "llm"

proc effectiveScript*(seat: SeatRegistration): ScriptKind =
  if seat.scripted != skNone:
    seat.scripted
  elif strutils.strip(seat.prompt).len == 0:
    skDispatcher
  else:
    skNone
