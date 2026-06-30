#!/bin/zsh
set -euo pipefail

# Required-tool preflight for AI launcher sessions.
# No Homebrew operations are performed here. When remediation is allowed, this
# script only attempts scoped PATH remediation for the requested tools.

AI_REQUIRED_TOOLS="${AI_REQUIRED_TOOLS:-git zsh python3 rg}"
AI_ALLOW_TOOL_REMEDIATION="${AI_ALLOW_TOOL_REMEDIATION:-0}"

typeset -a REQUIRED_TOOLS
REQUIRED_TOOLS=("${(@s: :)AI_REQUIRED_TOOLS}")

typeset -a CURRENT_MISSING SUBSHELL_MISSING

check_current_shell() {
  local tool="$1"
  command -v "$tool" >/dev/null 2>&1
}

check_zsh_subshell() {
  local tool="$1"
  zsh -c 'command -v "$1" >/dev/null 2>&1' _ "$tool"
}

collect_failures() {
  CURRENT_MISSING=()
  SUBSHELL_MISSING=()

  local tool
  for tool in "${REQUIRED_TOOLS[@]}"; do
    [[ -n "$tool" ]] || continue
    if check_current_shell "$tool"; then
      print "✓ current shell: $tool -> $(command -v "$tool")"
    else
      print -u2 "✗ current shell: missing $tool"
      CURRENT_MISSING+=("$tool")
    fi

    if check_zsh_subshell "$tool"; then
      print "✓ zsh -c: $tool visible"
    else
      print -u2 "✗ zsh -c: missing $tool"
      SUBSHELL_MISSING+=("$tool")
    fi
  done
}

attempt_path_remediation() {
  print "Attempting scoped PATH-only remediation for: ${AI_REQUIRED_TOOLS}"
  print "No package-manager operations will be run. Homebrew install/update remains disallowed unless separately authorized."

  typeset -a candidate_paths
  candidate_paths=(
    /Library/TeX/texbin
    /opt/homebrew/bin
    /opt/homebrew/sbin
    /usr/local/bin
    /usr/local/sbin
    /usr/bin
    /bin
    /usr/sbin
    /sbin
    "$HOME/.local/bin"
    "$HOME/.grok/bin"
  )

  local p
  for p in "${candidate_paths[@]}"; do
    [[ -d "$p" ]] || continue
    case ":$PATH:" in
      *":$p:"*) ;;
      *) PATH="$p:$PATH" ;;
    esac
  done
  export PATH
}

print "=== Tool preflight ==="
print "Required tools: ${AI_REQUIRED_TOOLS}"
print "Remediation allowed: ${AI_ALLOW_TOOL_REMEDIATION}"
print ""

collect_failures

if (( ${#CURRENT_MISSING[@]} || ${#SUBSHELL_MISSING[@]} )); then
  print ""
  if [[ "$AI_ALLOW_TOOL_REMEDIATION" == "1" ]]; then
    attempt_path_remediation
    print ""
    print "Rechecking after remediation..."
    collect_failures
  fi
fi

if (( ${#CURRENT_MISSING[@]} || ${#SUBSHELL_MISSING[@]} )); then
  print ""
  print -u2 "ERROR: tool preflight failed."
  if (( ${#CURRENT_MISSING[@]} )); then
    print -u2 "Missing in current shell: ${CURRENT_MISSING[*]}"
  fi
  if (( ${#SUBSHELL_MISSING[@]} )); then
    print -u2 "Missing in zsh -c: ${SUBSHELL_MISSING[*]}"
    print -u2 "Check non-interactive zsh PATH configuration, especially /etc/zshenv."
  fi
  print -u2 "Set AI_ALLOW_TOOL_REMEDIATION=1 only for scoped PATH remediation."
  exit 1
fi

print ""
print "Tool preflight passed."
