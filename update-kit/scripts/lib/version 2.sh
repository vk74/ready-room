#!/usr/bin/env bash
#
# Version: 0.26.2
# Purpose: Shared semantic-version comparison for update-kit scripts.
# Sourceable library (no set -euo, no side effects, no output when sourced).
# File: version.sh
#
# compare_versions v1 v2 — return codes:
#   0  if v1 == v2
#   1  if v1 > v2
#   2  if v1 < v2
#
# Pre-release ordering (leading "v" is stripped first):
#   - Base X.Y.Z segments are compared numerically: 0.12.14 > 0.12.13
#   - A pre-release is always less than the same base: 0.23.1-beta1 < 0.23.1
#     (also 0.12.14-b2 < 0.12.14). A release with no suffix is greater than
#     any pre-release of the same base.
#   - Two pre-releases of the same base compare by the numeric part of the
#     suffix: 0.12.14-b1 < 0.12.14-b2, 0.23.1-beta1 < 0.23.1-beta2
#   - Bare X.Y.Z comparisons are unchanged vs the historical implementations.
#
# Changes in v0.26.2:
# - Double-source guard is APP_LIB_VERSION_SH.
#
# Changes in v0.23.2:
# - Initial shared library: pre-release-aware compare_versions extracted from
#   the apply-update.sh / check-updates.sh / download-update.sh / list-releases.sh
#   copies so run-migrations.sh and the other callers share one definition.
#
# Guard against double-sourcing. When this file is executed directly (not sourced)
# the first load defines the function and exits with no output.
if [[ -n "${APP_LIB_VERSION_SH:-}" ]]; then
  return 0
fi
APP_LIB_VERSION_SH=1

# Returns: 0 if v1 == v2, 1 if v1 > v2, 2 if v1 < v2
compare_versions() {
  local v1="$1" v2="$2"
  v1="${v1#v}"
  v2="${v2#v}"
  [[ "$v1" == "$v2" ]] && return 0

  # Separate base version and pre-release suffix (e.g. 0.23.1-beta1 → 0.23.1 / beta1)
  local base1="${v1%%-*}" pre1=""
  [[ "$v1" == *-* ]] && pre1="${v1#*-}"
  local base2="${v2%%-*}" pre2=""
  [[ "$v2" == *-* ]] && pre2="${v2#*-}"

  local IFS='.' i
  local -a ver1=($base1) ver2=($base2)
  for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do ver1[i]=0; done
  for ((i=${#ver2[@]}; i<${#ver1[@]}; i++)); do ver2[i]=0; done

  for ((i=0; i<${#ver1[@]}; i++)); do
    local n1="${ver1[i]}" n2="${ver2[i]}"
    ((10#$n1 > 10#$n2)) && return 1
    ((10#$n1 < 10#$n2)) && return 2
  done

  # Base versions equal — a release with no suffix is greater than any pre-release
  if [[ -z "$pre1" ]] && [[ -n "$pre2" ]]; then return 1; fi
  if [[ -n "$pre1" ]] && [[ -z "$pre2" ]]; then return 2; fi
  if [[ -n "$pre1" ]] && [[ -n "$pre2" ]]; then
    # Numeric part of the suffix: beta1 / b2 → 1 / 2
    local num1="${pre1//[!0-9]/}" num2="${pre2//[!0-9]/}"
    num1="${num1:-0}"
    num2="${num2:-0}"
    ((10#$num1 > 10#$num2)) && return 1
    ((10#$num1 < 10#$num2)) && return 2
  fi
  return 0
}
