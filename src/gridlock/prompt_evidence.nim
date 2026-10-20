## Private provenance derived from the actual retained attempts, including retries.
import std/json
import bitworld/decision_trajectory
import prompts

proc promptObservation*(view: JsonNode, selection: PromptSelection,
    attempts: seq[DecisionAttempt]): JsonNode =
  result = copy(view)
  result["prompt_selection"] = selection.selectionMetadata()
  var metadata = newJArray()
  for attempt in attempts:
    if attempt.origin in {aoModel, aoTeacher}:
      metadata.add(%*{"attempt_id": attempt.attemptId,
        "prompt_template": selection.promptMetadata(
          attempt.prompt[0]["content"].getStr(), attempt.prompt[1]["content"].getStr())})
  result["prompt_attempts"] = metadata
