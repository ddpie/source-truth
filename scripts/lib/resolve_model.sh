#!/usr/bin/env bash
# resolve_model.sh — pick the Bedrock inference profile that actually exists in a
# region, by ASKING AWS rather than guessing a prefix.
#
# Why not guess: Bedrock cross-region inference profiles are NOT a simple
# region→prefix formula. Per the Claude Opus 4.8 model card, the geo profiles are
# us. / eu. / jp. / au. (there is no apac.), and most AP regions (Singapore, Mumbai,
# Seoul, …) have NO geo profile at all — they only carry `global.`. The available
# set also changes over time as AWS adds regions. Any hardcoded table is wrong the
# day AWS edits theirs. So we query `bedrock list-inference-profiles` for the region
# and choose from what's really offered.
#
# Selection, given a desired model basename (e.g. claude-opus-4-8) and the region's
# available SYSTEM_DEFINED profile IDs:
#   1. an in-region / geo profile for that model (us.|eu.|jp.|au.<...>) — preferred
#      (lower latency, respects data residency), OR
#   2. the global.<...> profile if no geo one is offered, OR
#   3. nothing → caller keeps the operator's id and lets the existing invoke-probe WARN.
#
# `model_basename` and `rank_profiles` are PURE (no I/O) so tests can drive the
# selection logic with a fixed candidate list. `list_region_profiles` and
# `resolve_model_for_region` do the AWS call (skipped in dry-run by the caller).

# model_basename <model-id> -> the bare model name, stripping any
# global./us./eu./jp./au./anthropic. prefix. Used to match against profile ids
# regardless of the prefix the operator happened to type.
#   global.anthropic.claude-opus-4-8 -> claude-opus-4-8
#   apac.anthropic.claude-opus-4-8   -> claude-opus-4-8   (even a bogus prefix)
#   anthropic.claude-opus-4-8        -> claude-opus-4-8
#   claude-opus-4-8                  -> claude-opus-4-8
model_basename() {
  local m="$1"
  m="${m##*anthropic.}"   # drop everything up to and including the last 'anthropic.'
  echo "$m"
}

# rank_profiles <model-basename> <profile-id>...  -> echoes the single best profile id
# for that model from the candidates, or nothing if none match. Geo beats global.
# PURE — no I/O; the candidate list is passed in (from list_region_profiles or a test).
rank_profiles() {
  local base="$1"; shift
  local p geo="" glob=""
  for p in "$@"; do
    # Must be the SAME model: the id ends with the basename (e.g. us.anthropic.claude-opus-4-8).
    [[ "$p" == *"$base" ]] || continue
    case "$p" in
      global.*) glob="$p" ;;
      *)        [[ -z "$geo" ]] && geo="$p" ;;   # first geo/in-region match wins
    esac
  done
  # Prefer a geo/in-region profile; fall back to global.
  if [[ -n "$geo" ]]; then echo "$geo"; elif [[ -n "$glob" ]]; then echo "$glob"; fi
}

# list_region_profiles <region> -> echoes the region's SYSTEM_DEFINED inference profile
# ids, one per line. Network call (needs aws + bedrock:ListInferenceProfiles). Returns
# nonzero (and no output) if the call fails — caller treats that as "couldn't resolve".
list_region_profiles() {
  command -v aws >/dev/null 2>&1 || return 1
  aws bedrock list-inference-profiles --region "$1" --type-equals SYSTEM_DEFINED \
    --query 'inferenceProfileSummaries[].inferenceProfileId' --output text 2>/dev/null \
    | tr '\t' '\n'
}

# resolve_model_for_region <model-id> <region> -> echoes the region-correct profile id.
# Asks AWS what's offered and picks the best match for the model. If AWS can't be
# reached, the model can't be matched, or anything is uncertain, echoes the ORIGINAL
# id unchanged — we never invent an id, and the downstream invoke-probe still WARNs if
# the kept id turns out to be unavailable. Non-fatal by construction.
resolve_model_for_region() {
  local model="$1" region="$2"
  local base; base="$(model_basename "$model")"
  [[ -n "$base" ]] || { echo "$model"; return 0; }
  local profiles; profiles="$(list_region_profiles "$region")" || { echo "$model"; return 0; }
  [[ -n "$profiles" ]] || { echo "$model"; return 0; }
  local best; best="$(rank_profiles "$base" $profiles)"
  if [[ -n "$best" ]]; then echo "$best"; else echo "$model"; fi
}
