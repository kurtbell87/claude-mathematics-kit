#!/usr/bin/env bash
# math.sh -- Formal Mathematics Workflow Orchestrator for Claude Code
#
# Usage:
#   ./math.sh survey    <spec-file>       # Survey Mathlib, domain, existing formalizations
#   ./math.sh specify   <spec-file>       # Write precise property requirements (no Lean4)
#   ./math.sh construct <spec-file>       # Informal math: definitions, theorems, proof sketches
#   ./math.sh formalize <spec-file>       # Write .lean defs + theorems (all sorry)
#   ./math.sh prove     <spec-file>       # Fill sorrys via lake build loop
#   ./math.sh audit     <spec-file>       # Verify coverage, zero sorry/axiom
#   ./math.sh log       <spec-file>       # Git commit + PR
#   ./math.sh full      <spec-file>       # Run all 7 phases with revision loop
#   ./math.sh program   [--max-cycles N]  # Auto-advance through CONSTRUCTIONS.md
#   ./math.sh status                      # Show sorry count, axiom count, build status
#   ./math.sh watch     [phase]           # Live-tail a running phase log
#
# Configure via environment variables or edit the defaults below.

set -euo pipefail

# ──────────────────────────────────────────────────────────────
# Configuration -- edit these to match your project
# ──────────────────────────────────────────────────────────────

LEAN_DIR="${LEAN_DIR:-.}"                          # Root of Lean4 project
SPEC_DIR="${SPEC_DIR:-specs}"                      # Spec & construction docs
RESULTS_DIR="${RESULTS_DIR:-results}"              # Archived results
PROMPT_DIR=".claude/prompts"                       # Phase-specific prompt files
HOOK_DIR=".claude/hooks"                           # Hook scripts

# Lean4 build command
LAKE_BUILD="${LAKE_BUILD:-lake build}"

# Revision limits
MAX_REVISIONS="${MAX_REVISIONS:-3}"                # Max revision cycles before giving up

# Program mode
MAX_PROGRAM_CYCLES="${MAX_PROGRAM_CYCLES:-20}"
CONSTRUCTIONS_FILE="${CONSTRUCTIONS_FILE:-CONSTRUCTIONS.md}"

# Post-cycle PR settings
MATH_AUTO_MERGE="${MATH_AUTO_MERGE:-false}"
MATH_DELETE_BRANCH="${MATH_DELETE_BRANCH:-false}"
MATH_BASE_BRANCH="${MATH_BASE_BRANCH:-main}"

# ──────────────────────────────────────────────────────────────
# Colors
# ──────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# ──────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────

find_lean_files() {
  find "$LEAN_DIR" -type f -name "*.lean" \
    ! -path "*/.lake/*" \
    ! -path "*/lake-packages/*" \
    ! -path "*/.git/*" \
    ! -path "*/.elan/*" \
    2>/dev/null || true
}

count_sorrys() {
  local total=0
  while IFS= read -r f; do
    local count
    count=$(grep -c '\bsorry\b' "$f" 2>/dev/null) || count=0
    total=$((total + count))
  done < <(find_lean_files)
  echo "$total"
}

check_axioms() {
  local total=0
  while IFS= read -r f; do
    for pattern in '\baxiom\b' '\bunsafe\b' '\bnative_decide\b' '\badmit\b'; do
      local count
      count=$(grep -c "$pattern" "$f" 2>/dev/null) || count=0
      total=$((total + count))
    done
  done < <(find_lean_files)
  echo "$total"
}

extract_theorem_signatures() {
  # Extract all theorem/lemma names from .lean files
  while IFS= read -r f; do
    grep -nE '^\s*(theorem|lemma|instance)\s+' "$f" 2>/dev/null | while IFS= read -r line; do
      echo "$f:$line"
    done
  done < <(find_lean_files)
}

construction_id_from_spec() {
  local spec="$1"
  basename "$spec" .md
}

results_dir_for_spec() {
  local spec="$1"
  local cid
  cid="$(construction_id_from_spec "$spec")"
  echo "$RESULTS_DIR/$cid"
}

# ── Locking ──

lock_spec() {
  local spec="$1"
  if [[ -f "$spec" ]]; then
    chmod 444 "$spec"
    echo -e "   ${YELLOW}locked:${NC} $spec"
  fi
  # Also lock construction docs in specs/
  local cid
  cid="$(construction_id_from_spec "$spec")"
  for f in "$SPEC_DIR"/construction-"$cid"*; do
    if [[ -f "$f" ]]; then
      chmod 444 "$f"
      echo -e "   ${YELLOW}locked:${NC} $f"
    fi
  done
  # Lock DOMAIN_CONTEXT.md
  if [[ -f "DOMAIN_CONTEXT.md" ]]; then
    chmod 444 "DOMAIN_CONTEXT.md"
    echo -e "   ${YELLOW}locked:${NC} DOMAIN_CONTEXT.md"
  fi
}

unlock_spec() {
  local spec="$1"
  if [[ -f "$spec" ]]; then
    chmod 644 "$spec"
    echo -e "   ${BLUE}unlocked:${NC} $spec"
  fi
  local cid
  cid="$(construction_id_from_spec "$spec")"
  for f in "$SPEC_DIR"/construction-"$cid"*; do
    if [[ -f "$f" ]]; then
      chmod 644 "$f"
      echo -e "   ${BLUE}unlocked:${NC} $f"
    fi
  done
  if [[ -f "DOMAIN_CONTEXT.md" ]]; then
    chmod 644 "DOMAIN_CONTEXT.md"
    echo -e "   ${BLUE}unlocked:${NC} DOMAIN_CONTEXT.md"
  fi
}

lock_lean_files() {
  echo -e "${YELLOW}Locking .lean files...${NC}"
  local count=0
  while IFS= read -r f; do
    chmod 444 "$f"
    echo -e "   ${YELLOW}locked:${NC} $f"
    ((count++))
  done < <(find_lean_files)
  echo -e "   ${YELLOW}$count file(s) locked${NC}"
}

unlock_lean_files() {
  echo -e "${BLUE}Unlocking .lean files...${NC}"
  local count=0
  while IFS= read -r f; do
    chmod 644 "$f"
    ((count++))
  done < <(find_lean_files)
  echo -e "   ${BLUE}$count file(s) unlocked${NC}"
}

unlock_all() {
  # Restore write permissions on everything
  while IFS= read -r f; do
    chmod 644 "$f" 2>/dev/null || true
  done < <(find_lean_files)
  find "$SPEC_DIR" -type f -name "*.md" -exec chmod 644 {} \; 2>/dev/null || true
  find "$SPEC_DIR" -type d -exec chmod 755 {} \; 2>/dev/null || true
  if [[ -f "DOMAIN_CONTEXT.md" ]]; then
    chmod 644 "DOMAIN_CONTEXT.md" 2>/dev/null || true
  fi
  echo -e "   ${BLUE}all files unlocked${NC}"
}

ensure_hooks_executable() {
  if [[ -f "$HOOK_DIR/pre-tool-use.sh" ]]; then
    chmod +x "$HOOK_DIR/pre-tool-use.sh"
  fi
}

# ──────────────────────────────────────────────────────────────
# Status
# ──────────────────────────────────────────────────────────────

run_status() {
  echo ""
  echo -e "${BOLD}Mathematics Construction Status${NC}"
  echo -e "${BOLD}===============================${NC}"
  echo ""

  # Lean files
  local lean_count
  lean_count=$(find_lean_files | wc -l | tr -d ' ')
  echo -e "${CYAN}Lean4 Files:${NC} $lean_count"

  # Sorry count
  local sorry_count
  sorry_count=$(count_sorrys)
  if [[ "$sorry_count" -eq 0 ]]; then
    echo -e "${CYAN}Sorry Count:${NC} ${GREEN}0${NC}"
  else
    echo -e "${CYAN}Sorry Count:${NC} ${RED}$sorry_count${NC}"
  fi

  # Axiom/unsafe count
  local axiom_count
  axiom_count=$(check_axioms)
  if [[ "$axiom_count" -eq 0 ]]; then
    echo -e "${CYAN}Axiom/Unsafe:${NC} ${GREEN}0${NC}"
  else
    echo -e "${CYAN}Axiom/Unsafe:${NC} ${RED}$axiom_count${NC}"
  fi

  # Lake build status
  echo -n -e "${CYAN}Lake Build:${NC}  "
  if eval "$LAKE_BUILD" 2>&1 | tail -1 | grep -qi 'error'; then
    echo -e "${RED}FAIL${NC}"
  else
    echo -e "${GREEN}PASS${NC}"
  fi

  # Lock states
  echo ""
  echo -e "${CYAN}Lock States:${NC}"
  local locked_specs=0 locked_lean=0
  while IFS= read -r f; do
    if [[ ! -w "$f" ]]; then
      locked_specs=$((locked_specs + 1))
    fi
  done < <(find "$SPEC_DIR" -type f -name "*.md" 2>/dev/null || true)
  while IFS= read -r f; do
    if [[ ! -w "$f" ]]; then
      locked_lean=$((locked_lean + 1))
    fi
  done < <(find_lean_files)
  echo -e "  Spec files locked:  $locked_specs"
  echo -e "  Lean files locked:  $locked_lean"

  # Current phase
  echo ""
  echo -e "${CYAN}Phase:${NC} ${MATH_PHASE:-not set}"

  # Theorem list
  echo ""
  echo -e "${CYAN}Theorems:${NC}"
  extract_theorem_signatures | while IFS= read -r sig; do
    echo "  $sig"
  done
  echo ""

  # Revision status
  if [[ -f "REVISION.md" ]]; then
    echo -e "${YELLOW}REVISION.md exists${NC} — revision cycle pending"
    local restart_from
    restart_from=$(grep -m1 '^## restart_from:' "REVISION.md" 2>/dev/null | sed 's/^## restart_from:[[:space:]]*//' || echo "unknown")
    echo -e "  Restart from: ${BOLD}$restart_from${NC}"
  fi

  # Constructions queue
  if [[ -f "$CONSTRUCTIONS_FILE" ]]; then
    echo ""
    echo -e "${CYAN}Construction Queue ($CONSTRUCTIONS_FILE):${NC}"
    grep -E '^\| P[0-9]' "$CONSTRUCTIONS_FILE" 2>/dev/null | while IFS= read -r line; do
      echo "  $line"
    done
  fi

  echo ""
}

# ──────────────────────────────────────────────────────────────
# Phase Runners
# ──────────────────────────────────────────────────────────────

run_survey() {
  local spec_file="${1:?Usage: math.sh survey <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  echo ""
  echo -e "${CYAN}======================================================${NC}"
  echo -e "${CYAN}  SURVEY PHASE -- Domain & Mathlib Reconnaissance${NC}"
  echo -e "${CYAN}======================================================${NC}"
  echo -e "  Spec: $spec_file"
  echo ""

  export MATH_PHASE="survey"

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/math-survey.md")

## Context
- Spec file: $spec_file
- Lean project root: $LEAN_DIR
- Build command: $LAKE_BUILD
- Existing .lean files: $(find_lean_files | tr '\n' ', ' || echo 'none')
- Domain context: DOMAIN_CONTEXT.md

Read the spec file first, then survey Mathlib and existing formalizations." \
    --allowed-tools "Read,Bash,Glob,Grep" \
    -p "Read the spec file at $spec_file, then survey Mathlib and existing formalizations for this domain." \
    2>&1 | tee /tmp/math-survey.log
}

run_specify() {
  local spec_file="${1:?Usage: math.sh specify <spec-file>}"

  echo ""
  echo -e "${BLUE}======================================================${NC}"
  echo -e "${BLUE}  SPECIFY PHASE -- Property Requirements${NC}"
  echo -e "${BLUE}======================================================${NC}"
  echo -e "  Spec: $spec_file"
  echo ""

  mkdir -p "$SPEC_DIR"

  export MATH_PHASE="specify"
  ensure_hooks_executable

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/math-specify.md")

## Context
- Spec file to write: $spec_file
- Spec directory: $SPEC_DIR
- Domain context: DOMAIN_CONTEXT.md
- Existing specs: $(find "$SPEC_DIR" -name "*.md" -type f 2>/dev/null | tr '\n' ', ' || echo 'none')
- Construction spec template: templates/construction-spec.md (if available)

Write precise property requirements to $spec_file. Update DOMAIN_CONTEXT.md with Mathlib mappings." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Write precise mathematical property requirements to $spec_file" \
    2>&1 | tee /tmp/math-specify.log
}

run_construct() {
  local spec_file="${1:?Usage: math.sh construct <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  echo ""
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "${MAGENTA}  CONSTRUCT PHASE -- Informal Mathematics${NC}"
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "  Spec: $spec_file"
  echo ""

  export MATH_PHASE="construct"
  ensure_hooks_executable

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/math-construct.md")

## Context
- Spec file: $spec_file (READ -- these are your requirements)
- Spec directory: $SPEC_DIR (write construction docs here)
- Domain context: DOMAIN_CONTEXT.md
- Existing .lean files: $(find_lean_files | tr '\n' ', ' || echo 'none')

Read the spec, then write an informal construction document with definitions, theorems, and proof sketches." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Read the spec at $spec_file, then write a construction document with definitions, theorems, and proof sketches." \
    2>&1 | tee /tmp/math-construct.log
}

run_formalize() {
  local spec_file="${1:?Usage: math.sh formalize <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  echo ""
  echo -e "${YELLOW}======================================================${NC}"
  echo -e "${YELLOW}  FORMALIZE PHASE -- Lean4 Definitions + Sorry Theorems${NC}"
  echo -e "${YELLOW}======================================================${NC}"
  echo -e "  Spec: $spec_file"
  echo -e "  Build: $LAKE_BUILD"
  echo ""

  export MATH_PHASE="formalize"
  ensure_hooks_executable

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/math-formalize.md")

## Context
- Spec file: $spec_file (READ -- do not modify)
- Construction docs: $(find "$SPEC_DIR" -name "construction-*" -type f 2>/dev/null | tr '\n' ', ' || echo 'none')
- Domain context: DOMAIN_CONTEXT.md
- Build command: $LAKE_BUILD
- Existing .lean files: $(find_lean_files | tr '\n' ', ' || echo 'none')

Read the spec and construction docs, then write .lean files with ALL proof bodies as sorry. Verify with $LAKE_BUILD." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Read the spec and construction docs, then write Lean4 files with definitions and sorry theorems. Verify with '$LAKE_BUILD'." \
    2>&1 | tee /tmp/math-formalize.log
}

run_prove() {
  local spec_file="${1:?Usage: math.sh prove <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  local lean_count
  lean_count=$(find_lean_files | wc -l | tr -d ' ')
  if [[ "$lean_count" -eq 0 ]]; then
    echo -e "${RED}Error: No .lean files found. Run 'math.sh formalize' first.${NC}" >&2
    exit 1
  fi

  local sorry_count
  sorry_count=$(count_sorrys)

  echo ""
  echo -e "${GREEN}======================================================${NC}"
  echo -e "${GREEN}  PROVE PHASE -- Filling Sorrys${NC}"
  echo -e "${GREEN}======================================================${NC}"
  echo -e "  Spec:    $spec_file ${YELLOW}(READ-ONLY)${NC}"
  echo -e "  Sorrys:  $sorry_count"
  echo -e "  Build:   $LAKE_BUILD"
  echo ""

  # OS-level enforcement: lock specs
  lock_spec "$spec_file"
  ensure_hooks_executable

  export MATH_PHASE="prove"

  # Unlock specs on exit
  trap "unlock_spec '$spec_file' 2>/dev/null || true" EXIT

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/math-prove.md")

## Context
- Spec file: $spec_file (READ-ONLY -- OS-enforced, do not modify)
- Construction docs: $(find "$SPEC_DIR" -name "construction-*" -type f 2>/dev/null | tr '\n' ', ' || echo 'none')
- Domain context: DOMAIN_CONTEXT.md (READ-ONLY)
- Build command: $LAKE_BUILD
- Current sorry count: $sorry_count
- .lean files: $(find_lean_files | tr '\n' ', ')

Read the .lean files and spec. Replace sorrys with real proofs using Edit. Run '$LAKE_BUILD' after each change." \
    --allowed-tools "Read,Edit,Bash,Glob,Grep,Write" \
    -p "Fill in all sorry placeholders with real Lean4 proofs. Use Edit to replace sorry. Run '$LAKE_BUILD' after each change. Current sorry count: $sorry_count" \
    2>&1 | tee /tmp/math-prove.log
}

run_audit() {
  local spec_file="${1:?Usage: math.sh audit <spec-file>}"

  if [[ ! -f "$spec_file" ]]; then
    echo -e "${RED}Error: Spec file not found: $spec_file${NC}" >&2
    exit 1
  fi

  echo ""
  echo -e "${RED}======================================================${NC}"
  echo -e "${RED}  AUDIT PHASE -- Verification & Coverage Check${NC}"
  echo -e "${RED}======================================================${NC}"
  echo -e "  Spec:  $spec_file"
  echo ""

  # OS-level enforcement: lock all .lean files
  lock_lean_files
  lock_spec "$spec_file"
  ensure_hooks_executable

  export MATH_PHASE="audit"

  # Unlock on exit
  trap "unlock_all 2>/dev/null || true" EXIT

  local sorry_count
  sorry_count=$(count_sorrys)
  local axiom_count
  axiom_count=$(check_axioms)

  claude \
    --output-format stream-json \
    --append-system-prompt "$(cat "$PROMPT_DIR/math-audit.md")

## Context
- Spec file: $spec_file (READ-ONLY)
- .lean files: $(find_lean_files | tr '\n' ', ') (ALL READ-ONLY)
- Build command: $LAKE_BUILD
- Current sorry count: $sorry_count
- Current axiom/unsafe count: $axiom_count
- Construction log: CONSTRUCTION_LOG.md (WRITE to this)
- Domain context: DOMAIN_CONTEXT.md

Run '$LAKE_BUILD', audit all .lean files, check spec coverage. Write results to CONSTRUCTION_LOG.md." \
    --allowed-tools "Read,Write,Edit,Bash,Glob,Grep" \
    -p "Audit the formalization. Run '$LAKE_BUILD', check for sorry/axiom, verify spec coverage. Write results to CONSTRUCTION_LOG.md." \
    2>&1 | tee /tmp/math-audit.log
}

run_log() {
  local spec_file="${1:?Usage: math.sh log <spec-file>}"
  local cid
  cid="$(construction_id_from_spec "$spec_file")"
  local results_path
  results_path="$(results_dir_for_spec "$spec_file")"

  echo ""
  echo -e "${MAGENTA}======================================================${NC}"
  echo -e "${MAGENTA}  LOG PHASE -- Committing & Creating PR${NC}"
  echo -e "${MAGENTA}======================================================${NC}"
  echo ""

  # Ensure everything is unlocked for commit
  unlock_all 2>/dev/null || true

  # Archive results
  mkdir -p "$results_path"
  cp "$spec_file" "$results_path/spec.md" 2>/dev/null || true
  if [[ -f "CONSTRUCTION_LOG.md" ]]; then
    cp "CONSTRUCTION_LOG.md" "$results_path/audit.md" 2>/dev/null || true
  fi

  # Copy .lean files to results for archival
  while IFS= read -r f; do
    local dest="$results_path/lean/$(basename "$f")"
    mkdir -p "$(dirname "$dest")"
    cp "$f" "$dest" 2>/dev/null || true
  done < <(find_lean_files)

  # Create feature branch
  local branch="math/${cid}"
  git checkout -b "$branch" 2>/dev/null || git checkout "$branch"

  # Stage and commit
  git add -A
  git commit -m "math(${cid}): formally verified construction

Spec: ${spec_file}
Results: ${results_path}/
Sorry count: $(count_sorrys)
Axiom count: $(check_axioms)

SURVEY -> SPECIFY -> CONSTRUCT -> FORMALIZE -> PROVE -> AUDIT complete."

  # Push and create PR
  git push -u origin "$branch"

  local pr_url
  pr_url=$(gh pr create \
    --base "$MATH_BASE_BRANCH" \
    --title "math(${cid}): formally verified construction" \
    --body "$(cat <<EOF
## Construction: ${cid}

**Spec:** \`${spec_file}\`
**Results:** \`${results_path}/\`

### Phases completed
- [x] SURVEY — Mathlib & domain surveyed
- [x] SPECIFY — property requirements written
- [x] CONSTRUCT — informal construction designed
- [x] FORMALIZE — Lean4 definitions + sorry theorems
- [x] PROVE — all sorrys eliminated
- [x] AUDIT — verification & coverage check

### Verification
- \`lake build\`: $(if eval "$LAKE_BUILD" 2>&1 | tail -1 | grep -qi error; then echo "FAIL"; else echo "PASS"; fi)
- Sorry count: $(count_sorrys)
- Axiom count: $(check_axioms)

---
*Generated by [claude-mathematics-kit](https://github.com/kurtbell87/claude-mathematics-kit)*
EOF
)")

  echo -e "  ${GREEN}PR created:${NC} $pr_url"

  if [[ "$MATH_AUTO_MERGE" == "true" ]]; then
    echo -e "  ${YELLOW}Auto-merging...${NC}"
    gh pr merge "$pr_url" --merge
    echo -e "  ${GREEN}Merged.${NC}"
    git checkout "$MATH_BASE_BRANCH"
    git pull
    if [[ "$MATH_DELETE_BRANCH" == "true" ]]; then
      git branch -d "$branch" 2>/dev/null || true
      echo -e "  ${GREEN}Branch deleted.${NC}"
    fi
  fi

  echo ""
  echo -e "${GREEN}======================================================${NC}"
  echo -e "${GREEN}  Logged! PR: $pr_url${NC}"
  echo -e "${GREEN}======================================================${NC}"
}

# ──────────────────────────────────────────────────────────────
# Full Cycle (with revision loop)
# ──────────────────────────────────────────────────────────────

run_full() {
  local spec_file="${1:?Usage: math.sh full <spec-file>}"
  local revision_count=0

  echo -e "${BOLD}Running full construction cycle: SURVEY -> SPECIFY -> CONSTRUCT -> FORMALIZE -> PROVE -> AUDIT -> LOG${NC}"
  echo ""

  # SURVEY
  run_survey "$spec_file"
  echo -e "\n${YELLOW}--- Survey complete. Specifying... ---${NC}\n"

  # SPECIFY
  run_specify "$spec_file"
  echo -e "\n${YELLOW}--- Specify complete. Constructing... ---${NC}\n"

  # Revision loop: CONSTRUCT -> FORMALIZE -> PROVE -> AUDIT
  while true; do
    # CONSTRUCT
    run_construct "$spec_file"
    echo -e "\n${YELLOW}--- Construct complete. Formalizing... ---${NC}\n"

    # FORMALIZE
    run_formalize "$spec_file"
    echo -e "\n${YELLOW}--- Formalize complete. Proving... ---${NC}\n"

    # PROVE
    run_prove "$spec_file"
    echo -e "\n${YELLOW}--- Prove complete. Auditing... ---${NC}\n"

    # AUDIT
    run_audit "$spec_file"

    # Check for revision request
    if [[ -f "REVISION.md" ]]; then
      revision_count=$((revision_count + 1))

      if (( revision_count >= MAX_REVISIONS )); then
        echo -e "\n${RED}Max revisions reached ($MAX_REVISIONS). Stopping.${NC}"
        echo -e "${RED}Manual intervention needed. See REVISION.md.${NC}"
        return 1
      fi

      local restart_from
      restart_from=$(grep -m1 'restart_from:' "REVISION.md" 2>/dev/null | sed 's/.*restart_from:[[:space:]]*//' || echo "CONSTRUCT")

      echo -e "\n${YELLOW}======================================================${NC}"
      echo -e "${YELLOW}  REVISION $revision_count/$MAX_REVISIONS -- Restarting from $restart_from${NC}"
      echo -e "${YELLOW}======================================================${NC}\n"

      # Archive the revision
      mkdir -p "$RESULTS_DIR/revisions"
      cp "REVISION.md" "$RESULTS_DIR/revisions/revision-${revision_count}.md"
      rm "REVISION.md"

      # Restart from the appropriate phase
      case "$restart_from" in
        CONSTRUCT|construct)
          continue
          ;;
        FORMALIZE|formalize)
          # Skip CONSTRUCT, go straight to FORMALIZE
          run_formalize "$spec_file"
          echo -e "\n${YELLOW}--- Formalize complete. Proving... ---${NC}\n"
          run_prove "$spec_file"
          echo -e "\n${YELLOW}--- Prove complete. Auditing... ---${NC}\n"
          run_audit "$spec_file"
          # Check again for revision
          if [[ -f "REVISION.md" ]]; then
            continue
          fi
          break
          ;;
        *)
          echo -e "${RED}Unknown restart_from: $restart_from. Defaulting to CONSTRUCT.${NC}"
          continue
          ;;
      esac
    else
      break
    fi
  done

  echo -e "\n${YELLOW}--- Audit complete. Logging... ---${NC}\n"

  # LOG
  run_log "$spec_file"

  echo ""
  echo -e "${BOLD}${GREEN}======================================================${NC}"
  echo -e "${BOLD}${GREEN}  Full construction cycle complete!${NC}"
  if (( revision_count > 0 )); then
    echo -e "${BOLD}${GREEN}  Revisions: $revision_count${NC}"
  fi
  echo -e "${BOLD}${GREEN}======================================================${NC}"
}

# ──────────────────────────────────────────────────────────────
# Program Mode
# ──────────────────────────────────────────────────────────────

select_next_construction() {
  # Parse CONSTRUCTIONS.md for the highest-priority non-completed construction
  python3 -c "
import re, sys

try:
    with open('$CONSTRUCTIONS_FILE') as f:
        content = f.read()
except FileNotFoundError:
    sys.exit(1)

lines = content.split('\n')
for line in lines:
    cells = [c.strip() for c in line.split('|')]
    cells = [c for c in cells if c]
    if len(cells) < 4:
        continue
    priority = cells[0]
    if not re.match(r'^P\d+$', priority):
        continue
    construction = cells[1].strip('_')
    spec_file = cells[2].strip('\`')
    status = cells[3].lower()
    if status in ('not started', 'specified', 'constructed', 'revision'):
        print(f'{spec_file}|{construction}|{status}')
        break
" 2>/dev/null || true
}

update_construction_status() {
  local spec_file="$1"
  local new_status="$2"
  # Update the status in CONSTRUCTIONS.md for the matching spec file
  if [[ -f "$CONSTRUCTIONS_FILE" ]]; then
    python3 -c "
import re

with open('$CONSTRUCTIONS_FILE') as f:
    content = f.read()

lines = content.split('\n')
updated = []
for line in lines:
    if '${spec_file}' in line and '|' in line:
        # Replace the status column
        cells = line.split('|')
        for i, cell in enumerate(cells):
            stripped = cell.strip().lower()
            if stripped in ('not started', 'specified', 'constructed', 'formalized', 'proved', 'audited', 'revision', 'blocked'):
                cells[i] = ' ${new_status} '
                break
        line = '|'.join(cells)
    updated.append(line)

with open('$CONSTRUCTIONS_FILE', 'w') as f:
    f.write('\n'.join(updated))
" 2>/dev/null || true
  fi
}

run_program() {
  local max_cycles="$MAX_PROGRAM_CYCLES"

  # Parse arguments
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --max-cycles) max_cycles="$2"; shift 2 ;;
      *)            echo -e "${RED}Unknown argument: $1${NC}" >&2; return 1 ;;
    esac
  done

  echo ""
  echo -e "${BOLD}${CYAN}======================================================${NC}"
  echo -e "${BOLD}${CYAN}  PROGRAM MODE -- Auto-advancing Constructions${NC}"
  echo -e "${BOLD}${CYAN}======================================================${NC}"
  echo -e "  Max cycles:      $max_cycles"
  echo -e "  Max revisions:   $MAX_REVISIONS per construction"
  echo -e "  Constructions:   $CONSTRUCTIONS_FILE"
  echo ""

  if [[ ! -f "$CONSTRUCTIONS_FILE" ]]; then
    echo -e "${RED}Error: $CONSTRUCTIONS_FILE not found.${NC}" >&2
    echo -e "Create it from the template: cp templates/CONSTRUCTIONS.md ." >&2
    exit 1
  fi

  # SIGINT trap
  trap 'echo -e "\n${YELLOW}Program loop interrupted.${NC}"; exit 130' INT

  local cycle=0
  while (( cycle < max_cycles )); do
    cycle=$((cycle + 1))

    echo ""
    echo -e "${CYAN}── Cycle $cycle/$max_cycles ──${NC}"

    # Check for revision
    if [[ -f "REVISION.md" ]]; then
      echo -e "${YELLOW}REVISION.md exists — handle revision before continuing.${NC}"
      return 1
    fi

    # Select next construction
    local next
    next=$(select_next_construction)
    if [[ -z "$next" ]]; then
      echo -e "${GREEN}All constructions complete or blocked!${NC}"
      break
    fi

    local spec_file construction status
    IFS='|' read -r spec_file construction status <<< "$next"

    echo -e "${BOLD}Next:${NC} $construction"
    echo -e "${BOLD}Spec:${NC} $spec_file"
    echo -e "${BOLD}Status:${NC} $status"

    # Run the appropriate phases based on current status
    case "$status" in
      "not started")
        update_construction_status "$spec_file" "Specified"
        run_full "$spec_file" && update_construction_status "$spec_file" "Audited" || {
          echo -e "${RED}Construction failed for $spec_file${NC}"
          update_construction_status "$spec_file" "Revision"
          continue
        }
        ;;
      "specified")
        # Skip survey+specify, start from construct
        run_construct "$spec_file"
        run_formalize "$spec_file"
        run_prove "$spec_file"
        run_audit "$spec_file"
        if [[ ! -f "REVISION.md" ]]; then
          run_log "$spec_file"
          update_construction_status "$spec_file" "Audited"
        else
          update_construction_status "$spec_file" "Revision"
        fi
        ;;
      "constructed")
        run_formalize "$spec_file"
        run_prove "$spec_file"
        run_audit "$spec_file"
        if [[ ! -f "REVISION.md" ]]; then
          run_log "$spec_file"
          update_construction_status "$spec_file" "Audited"
        else
          update_construction_status "$spec_file" "Revision"
        fi
        ;;
      "revision")
        # Re-run full cycle
        update_construction_status "$spec_file" "Not started"
        run_full "$spec_file" && update_construction_status "$spec_file" "Audited" || {
          update_construction_status "$spec_file" "Blocked"
          continue
        }
        ;;
    esac

    echo -e "\n${GREEN}Cycle $cycle complete.${NC}"
  done

  echo ""
  echo -e "${BOLD}${GREEN}======================================================${NC}"
  echo -e "${BOLD}${GREEN}  Program mode complete. Cycles run: $cycle${NC}"
  echo -e "${BOLD}${GREEN}======================================================${NC}"
}

# ──────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────

case "${1:-help}" in
  survey)     shift; run_survey "$@" ;;
  specify)    shift; run_specify "$@" ;;
  construct)  shift; run_construct "$@" ;;
  formalize)  shift; run_formalize "$@" ;;
  prove)      shift; run_prove "$@" ;;
  audit)      shift; run_audit "$@" ;;
  log)        shift; run_log "$@" ;;
  full)       shift; run_full "$@" ;;
  program)    shift; run_program "$@" ;;
  status)     run_status ;;
  watch)      shift; python3 scripts/math-watch.py "$@" ;;
  help|*)
    echo "Usage: math.sh <phase> [args]"
    echo ""
    echo "Phases (run individually):"
    echo "  survey    <spec-file>    Survey Mathlib, domain, existing formalizations"
    echo "  specify   <spec-file>    Write precise property requirements (no Lean4)"
    echo "  construct <spec-file>    Informal math: definitions, theorems, proof sketches"
    echo "  formalize <spec-file>    Write .lean defs + theorem stmts (all sorry)"
    echo "  prove     <spec-file>    Fill sorrys via lake build loop (spec locked)"
    echo "  audit     <spec-file>    Verify coverage, zero sorry/axiom (.lean locked)"
    echo "  log       <spec-file>    Git commit + PR"
    echo ""
    echo "Pipelines:"
    echo "  full      <spec-file>    Run all 7 phases with revision loop"
    echo "  program   [--max-cycles N]  Auto-advance through CONSTRUCTIONS.md"
    echo ""
    echo "Utilities:"
    echo "  status                   Show sorry count, axiom count, build status"
    echo "  watch     [phase]        Live-tail a running phase (--resolve for summary)"
    echo ""
    echo "Environment:"
    echo "  LEAN_DIR='.'             Lean4 project root"
    echo "  SPEC_DIR='specs'         Spec & construction docs directory"
    echo "  LAKE_BUILD='lake build'  Build command"
    echo "  MAX_REVISIONS='3'        Max revision cycles per construction"
    echo "  MAX_PROGRAM_CYCLES='20'  Max cycles in program mode"
    echo "  MATH_AUTO_MERGE='false'  Auto-merge PR after creation"
    echo "  MATH_BASE_BRANCH='main'  Base branch for PRs"
    ;;
esac
