#!/usr/bin/env bash
# install.sh -- Bootstrap the Claude Mathematics Kit into your Lean4 project
#
# Usage:
#   cd your-lean-project && /path/to/claude-mathematics-kit/install.sh
#
# This script:
#   1. Copies kit files into your project root (safe, won't overwrite)
#   2. Checks for elan/lake toolchain
#   3. Initializes a Lean4+Mathlib project if needed
#   4. Creates specs/ and results/ directories
#   5. Handles existing CLAUDE.md

set -euo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'
BOLD='\033[1m'

# Determine where the kit files live (same directory as this script)
KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Target is the current working directory
TARGET_DIR="$(pwd)"

echo ""
echo -e "${BOLD}Claude Mathematics Kit -- Installer${NC}"
echo -e "Installing into: ${BLUE}$TARGET_DIR${NC}"
echo ""

# ── Helper: copy file if it doesn't exist ──
install_file() {
  local src="$1"
  local dest="$2"
  local dest_dir
  dest_dir="$(dirname "$dest")"

  mkdir -p "$dest_dir"

  if [[ -f "$dest" ]]; then
    echo -e "  ${YELLOW}exists:${NC}  $dest (skipped)"
  else
    cp "$src" "$dest"
    echo -e "  ${GREEN}created:${NC} $dest"
  fi
}

# ── Helper: copy file and make executable ──
install_executable() {
  local src="$1"
  local dest="$2"
  install_file "$src" "$dest"
  chmod +x "$dest"
}

# ──────────────────────────────────────────────────────────────
# Step 1: Check prerequisites
# ──────────────────────────────────────────────────────────────

echo -e "${BOLD}Prerequisites:${NC}"

# Check for elan / lake
HAVE_LAKE=true
if command -v lake &>/dev/null; then
  lake_version=$(lake --version 2>/dev/null | head -1 || echo "unknown")
  echo -e "  ${GREEN}found:${NC}   lake ($lake_version)"
elif command -v elan &>/dev/null; then
  elan_version=$(elan --version 2>/dev/null | head -1 || echo "unknown")
  echo -e "  ${GREEN}found:${NC}   elan ($elan_version)"
  echo -e "  ${YELLOW}note:${NC}    lake should be available via elan"
else
  HAVE_LAKE=false
  echo -e "  ${YELLOW}missing:${NC} lake / elan (Lean4 project setup will be skipped)"
  echo -e "  Install elan later: ${BOLD}curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf | sh${NC}"
fi

# Check for claude
if command -v claude &>/dev/null; then
  echo -e "  ${GREEN}found:${NC}   claude"
else
  echo -e "  ${YELLOW}warning:${NC} claude CLI not found (needed to run phases)"
fi

# Check for gh
if command -v gh &>/dev/null; then
  echo -e "  ${GREEN}found:${NC}   gh"
else
  echo -e "  ${YELLOW}warning:${NC} gh CLI not found (needed for LOG phase PRs)"
fi

# ──────────────────────────────────────────────────────────────
# Step 2: Core kit files
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Core orchestration:${NC}"
install_executable "$KIT_DIR/math.sh"          "$TARGET_DIR/math.sh"
install_file       "$KIT_DIR/math-aliases.sh"  "$TARGET_DIR/math-aliases.sh"

echo ""
echo -e "${BOLD}Monitoring:${NC}"
install_file "$KIT_DIR/scripts/math-watch.py" "$TARGET_DIR/scripts/math-watch.py"

# ──────────────────────────────────────────────────────────────
# Step 3: Claude hooks & prompts
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Claude Code hooks & prompts:${NC}"
install_executable "$KIT_DIR/.claude/hooks/pre-tool-use.sh"     "$TARGET_DIR/.claude/hooks/pre-tool-use.sh"
install_file       "$KIT_DIR/.claude/prompts/math-survey.md"    "$TARGET_DIR/.claude/prompts/math-survey.md"
install_file       "$KIT_DIR/.claude/prompts/math-specify.md"   "$TARGET_DIR/.claude/prompts/math-specify.md"
install_file       "$KIT_DIR/.claude/prompts/math-construct.md" "$TARGET_DIR/.claude/prompts/math-construct.md"
install_file       "$KIT_DIR/.claude/prompts/math-formalize.md" "$TARGET_DIR/.claude/prompts/math-formalize.md"
install_file       "$KIT_DIR/.claude/prompts/math-prove.md"     "$TARGET_DIR/.claude/prompts/math-prove.md"
install_file       "$KIT_DIR/.claude/prompts/math-audit.md"     "$TARGET_DIR/.claude/prompts/math-audit.md"

# ── Settings (merge-safe) ──
if [[ -f "$TARGET_DIR/.claude/settings.json" ]]; then
  echo ""
  echo -e "  ${YELLOW}exists:${NC}  .claude/settings.json"
  echo -e "  ${YELLOW}ACTION NEEDED:${NC} Merge the hook config manually. Add this to your settings.json:"
  echo ""
  echo '    "hooks": {'
  echo '      "PreToolUse": [{'
  echo '        "matcher": "Edit|Write|MultiEdit|Bash",'
  echo '        "hooks": [{"type": "command", "command": ".claude/hooks/pre-tool-use.sh"}]'
  echo '      }]'
  echo '    }'
  echo ""
else
  install_file "$KIT_DIR/.claude/settings.json" "$TARGET_DIR/.claude/settings.json"
fi

# ──────────────────────────────────────────────────────────────
# Step 4: Templates
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Template files:${NC}"
install_file "$KIT_DIR/templates/construction-spec.md" "$TARGET_DIR/templates/construction-spec.md"
install_file "$KIT_DIR/templates/CONSTRUCTIONS.md"     "$TARGET_DIR/CONSTRUCTIONS.md"
install_file "$KIT_DIR/templates/CONSTRUCTION_LOG.md"  "$TARGET_DIR/CONSTRUCTION_LOG.md"
install_file "$KIT_DIR/templates/DOMAIN_CONTEXT.md"    "$TARGET_DIR/DOMAIN_CONTEXT.md"
install_file "$KIT_DIR/templates/REVISION.md"          "$TARGET_DIR/templates/REVISION.md"

# ──────────────────────────────────────────────────────────────
# Step 5: CLAUDE.md handling
# ──────────────────────────────────────────────────────────────

if [[ -f "$TARGET_DIR/CLAUDE.md" ]]; then
  echo ""
  echo -e "  ${YELLOW}exists:${NC}  CLAUDE.md"
  # Check if it already has math kit content
  if grep -q "Mathematics Kit" "$TARGET_DIR/CLAUDE.md" 2>/dev/null; then
    echo -e "  ${BLUE}already contains:${NC} Mathematics Kit section (skipped)"
  else
    echo -e "  ${YELLOW}ACTION NEEDED:${NC} Append the math workflow to your CLAUDE.md."
    echo -e "  The snippet is at: ${BLUE}$KIT_DIR/templates/CLAUDE.md.snippet${NC}"
    echo -e "  Or run: ${BOLD}cat '$KIT_DIR/templates/CLAUDE.md.snippet' >> CLAUDE.md${NC}"
  fi
else
  cp "$KIT_DIR/templates/CLAUDE.md.snippet" "$TARGET_DIR/CLAUDE.md"
  echo -e "  ${GREEN}created:${NC} CLAUDE.md"
fi

# ──────────────────────────────────────────────────────────────
# Step 6: Project directories
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Project directories:${NC}"
mkdir -p "$TARGET_DIR/specs"
echo -e "  ${GREEN}ready:${NC}   specs/ (specification & construction docs)"
mkdir -p "$TARGET_DIR/results"
echo -e "  ${GREEN}ready:${NC}   results/ (archived construction results)"

# ──────────────────────────────────────────────────────────────
# Step 7: Lean4 project setup (requires lake)
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}Lean4 project:${NC}"

if [[ "$HAVE_LAKE" != "true" ]]; then
  echo -e "  ${YELLOW}skipped:${NC} lake not available — install elan, then re-run installer"
elif [[ -f "$TARGET_DIR/lakefile.lean" || -f "$TARGET_DIR/lakefile.toml" ]]; then
  echo -e "  ${GREEN}found:${NC}   lakefile exists"

  # Check if Mathlib is already a dependency
  if grep -q "Mathlib" "$TARGET_DIR/lakefile.lean" 2>/dev/null || \
     grep -q "Mathlib" "$TARGET_DIR/lakefile.toml" 2>/dev/null; then
    echo -e "  ${GREEN}found:${NC}   Mathlib dependency"
  else
    echo -e "  ${YELLOW}note:${NC}    Mathlib not found in lakefile"
    echo -e "  To add Mathlib, add this to your lakefile.lean:"
    echo ""
    echo '    require mathlib from git'
    echo '      "https://github.com/leanprover-community/mathlib4"'
    echo ""
    echo -e "  Then run: ${BOLD}lake update${NC}"
  fi
else
  echo -e "  ${YELLOW}No lakefile found.${NC}"

  # Determine project name from directory
  local_project_name=$(basename "$TARGET_DIR" | sed 's/[^a-zA-Z0-9]/_/g')

  echo -e "  Initializing Lean4 project: ${BOLD}$local_project_name${NC}"
  echo ""

  # Initialize Lean4 project with math template
  if lake init "$local_project_name" math 2>/dev/null; then
    echo -e "  ${GREEN}created:${NC} Lean4 project ($local_project_name)"
  else
    # Fallback: basic init
    lake init "$local_project_name" 2>/dev/null || {
      echo -e "  ${RED}Failed to initialize Lean4 project.${NC}" >&2
      echo -e "  Try manually: ${BOLD}lake init $local_project_name math${NC}" >&2
    }
  fi

  # Add Mathlib dependency if not present
  if [[ -f "$TARGET_DIR/lakefile.lean" ]] && ! grep -q "Mathlib" "$TARGET_DIR/lakefile.lean"; then
    echo "" >> "$TARGET_DIR/lakefile.lean"
    echo 'require mathlib from git' >> "$TARGET_DIR/lakefile.lean"
    echo '  "https://github.com/leanprover-community/mathlib4"' >> "$TARGET_DIR/lakefile.lean"
    echo -e "  ${GREEN}added:${NC}   Mathlib dependency to lakefile.lean"
  fi
fi

# ── Update Mathlib (if lake available) ──
if [[ "$HAVE_LAKE" == "true" ]]; then
  echo ""
  echo -e "${BOLD}Fetching dependencies:${NC}"
  echo -e "  Running ${BOLD}lake update${NC} (this may take a while for Mathlib)..."

  if lake update 2>&1; then
    echo -e "  ${GREEN}done:${NC}    lake update"
  else
    echo -e "  ${YELLOW}warning:${NC} lake update had issues (you may need to run it manually)"
  fi

  # ── Verify build ──
  echo ""
  echo -e "  Running ${BOLD}lake build${NC} to verify..."
  if lake build 2>&1; then
    echo -e "  ${GREEN}done:${NC}    lake build succeeds"
  else
    echo -e "  ${YELLOW}warning:${NC} lake build had issues (check your lakefile configuration)"
  fi
fi

# ──────────────────────────────────────────────────────────────
# Done
# ──────────────────────────────────────────────────────────────

echo ""
echo -e "${BOLD}${GREEN}Done!${NC}"
echo ""
echo -e "Next steps:"
echo -e "  1. Write your first spec: ${BLUE}cp templates/construction-spec.md specs/my-construction.md${NC}"
echo -e "  2. Edit the spec with your domain and requirements"
echo -e "  3. Run the full pipeline: ${BLUE}./math.sh full specs/my-construction.md${NC}"
echo -e "  4. Or run phases individually:"
echo -e "     ${BLUE}./math.sh survey specs/my-construction.md${NC}"
echo -e "     ${BLUE}./math.sh specify specs/my-construction.md${NC}"
echo -e "     ${BLUE}./math.sh construct specs/my-construction.md${NC}"
echo -e "     ${BLUE}./math.sh formalize specs/my-construction.md${NC}"
echo -e "     ${BLUE}./math.sh prove specs/my-construction.md${NC}"
echo -e "     ${BLUE}./math.sh audit specs/my-construction.md${NC}"
echo -e "     ${BLUE}./math.sh log specs/my-construction.md${NC}"
echo -e "  5. Check status: ${BLUE}./math.sh status${NC}"
echo -e "  6. Source aliases: ${BLUE}source math-aliases.sh${NC}"
echo -e "  7. Live monitor: ${BLUE}./math.sh watch prove${NC}"
echo ""
echo -e "For program mode (auto-advance through multiple constructions):"
echo -e "  1. Edit ${BLUE}CONSTRUCTIONS.md${NC} with your construction queue"
echo -e "  2. Run: ${BLUE}./math.sh program${NC}"
echo ""
