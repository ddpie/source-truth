#!/usr/bin/env bash
# resolve_model.sh — pick the right Bedrock inference-profile prefix for a region.
#
# Bedrock Claude model IDs are cross-region INFERENCE PROFILES, not bare model names:
#     <geo-prefix>.anthropic.<model>      e.g. apac.anthropic.claude-opus-4-8
#
# The geo prefix must match where you call from, and they are NOT interchangeable:
#   • us.    — US regions      (us-east-1, us-east-2, us-west-2, …)
#   • eu.    — EU regions       (eu-west-1/2/3, eu-central-1, …)
#   • apac.  — Asia-Pacific     (ap-northeast-1 Tokyo, ap-southeast-1 Singapore, …)
#   • global. — routes to ALL commercial regions, but is only CARRIED in a SUBSET of
#               source regions. Per AWS docs (inference-profiles-support), the global
#               profile's source regions are currently only us-west-2, us-east-1,
#               us-east-2, eu-west-1, and ap-northeast-1 (Tokyo). Calling a
#               global.* profile from e.g. ap-southeast-1 (Singapore) fails — which is
#               exactly the deploy error this resolver exists to prevent.
#
# So the safe, always-correct choice is the GEO-scoped prefix for the region. This
# resolver maps a region → geo prefix and rewrites a model id's prefix to match,
# UNLESS the operator pinned an explicit prefix on purpose (see below).
#
# Pure / no I/O — sourceable by scripts and unit tests.

# region_geo_prefix <aws-region> -> echoes "us" | "eu" | "apac" (default "us" for
# unknown so we never emit an invalid id; unknown is also logged by the caller).
region_geo_prefix() {
  case "$1" in
    us-*|us-gov-*) echo "us" ;;
    eu-*)          echo "eu" ;;
    ap-*)          echo "apac" ;;
    ca-*|sa-*)     echo "us" ;;   # no ca./sa. geo profile — these route via us.
    *)             echo "us" ;;   # unknown → safest non-empty default
  esac
}

# resolve_model_profile <model-id> <aws-region> -> echoes the region-correct model id.
#
# Behavior:
#   • A geo/global-prefixed id (us.|eu.|apac.|global.anthropic.<model>) has its prefix
#     REWRITTEN to the region's geo prefix — EXCEPT `global.`, which is left as-is
#     (an operator who wrote global. opted into it deliberately, e.g. from Tokyo where
#     it's carried; we only warn elsewhere — the caller decides whether to warn).
#   • A bare `anthropic.<model>` gets the region's geo prefix prepended.
#   • Anything else (already region-correct, or a form we don't recognize) is returned
#     unchanged so we never corrupt an id we don't understand.
resolve_model_profile() {
  local model="$1" region="$2"
  local geo; geo="$(region_geo_prefix "$region")"
  case "$model" in
    global.anthropic.*)
      # Operator explicitly chose global — respect it, don't rewrite. (Caller may warn
      # when the region isn't a known global source region.)
      echo "$model" ;;
    us.anthropic.*|eu.anthropic.*|apac.anthropic.*)
      # Rewrite the geo prefix to match the region.
      echo "${geo}.anthropic.${model#*.anthropic.}" ;;
    anthropic.*)
      # Bare provider-prefixed id → add the geo prefix.
      echo "${geo}.${model}" ;;
    *)
      # Unrecognized (already custom, non-Bedrock, etc.) → leave alone.
      echo "$model" ;;
  esac
}

# region_carries_global <aws-region> -> rc 0 if the region is a known source region for
# the `global.` inference profile, else rc 1. Per AWS docs (current set); used only to
# decide whether to WARN about a global.* id, never to block.
region_carries_global() {
  case "$1" in
    us-west-2|us-east-1|us-east-2|eu-west-1|ap-northeast-1) return 0 ;;
    *) return 1 ;;
  esac
}
