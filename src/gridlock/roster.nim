## Join, auth, slots and tokens. Forked in shape from paintbot's
## `src/ctf/roster.nim`, minus the reward/account machinery gridlock has no
## use for.
##
## A seat that never registers, or registers without a kind, plays the
## dispatcher baseline — a no-show never ends the episode.

import std/json
import types
import baselines

type
  PolicyKind* = enum
    pkScripted, pkPrompt, pkExternal

  SeatRegistration* = object
    kind*: PolicyKind
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
      kind: pkScripted, scripted: skDispatcher, policyLabel: "",
      connected: false, everConnected: false, registered: false)

proc authorize*(roster: Roster, slot: int, token: string): bool =
  slot >= 0 and slot < Seats and slot < roster.tokens.len and
    roster.tokens[slot].len > 0 and roster.tokens[slot] == token

proc applyRegistration*(roster: var Roster, slot: int, payload: JsonNode) =
  ## `{"type":"register","kind":…,"scripted":…,"policy":…}`.
  if slot < 0 or slot >= Seats:
    return
  if payload == nil or payload.kind != JObject:
    return
  if payload{"type"}.getStr("register") != "register":
    return
  let kind =
    case payload{"kind"}.getStr("scripted")
    of "scripted": pkScripted
    of "prompt": pkPrompt
    of "external": pkExternal
    else: raise newException(GridlockError, "unknown player kind")
  let scriptedNode = payload{"scripted"}
  let scripted =
    if scriptedNode == nil or scriptedNode.kind == JNull: skNone
    elif scriptedNode.kind == JBool:
      (if scriptedNode.getBool(): skDispatcher else: skNone)
    else: parseScriptKind(scriptedNode.getStr())
  let resolvedScript =
    if kind == pkScripted:
      if scripted == skNone: skDispatcher else: scripted
    else:
      if scripted != skNone:
        raise newException(GridlockError,
          "external or prompt player cannot register a scripted plan")
      skNone
  roster.seats[slot].kind = kind
  roster.seats[slot].scripted = resolvedScript
  roster.seats[slot].policyLabel =
    cleanLine(payload{"policy"}.getStr(), MaxPolicyRunes)
  roster.seats[slot].registered = true

proc policyKindOf*(seat: SeatRegistration): string =
  if seat.kind == pkScripted: "scripted" else: "llm"

proc effectiveScript*(seat: SeatRegistration): ScriptKind =
  ## What the seat REGISTERED as. `effectiveScriptNow` is what it plays this
  ## turn; the registration itself survives a drop so a reconnect revives it.
  seat.scripted

proc effectiveScriptNow*(seat: SeatRegistration): ScriptKind =
  ## A seat that connected and then dropped keeps playing, with its plan
  ## source degraded to `dispatcher` — there is nobody to answer for the
  ## policy, and a model call for an absent seat is spend with no owner. It
  ## revives on reconnect because the registration is untouched.
  if seat.everConnected and not seat.connected:
    skDispatcher
  else:
    effectiveScript(seat)
