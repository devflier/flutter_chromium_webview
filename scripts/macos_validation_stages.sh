# Sourced by validate_macos.sh after root and diagnostics are set.
# Independent checks continue after a failure; the final status stays nonzero.
failed_stages=()
run_stage() {
  local status=0
  python3 "$root/scripts/macos_diagnostic_stage.py" --directory "$diagnostics" "$@" || status=$?
  if (( status != 0 )); then
    failed_stages+=("$1 (exit $status)")
    echo "Validation stage failed: $1 (exit $status)" >&2
  fi
  return 0
}
finish_stage_validation() {
  if (( ${#failed_stages[@]} != 0 )); then
    printf 'Failed validation stage: %s\n' "${failed_stages[@]}" >&2
    return 1
  fi
}
