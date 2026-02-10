# Claude Mathematics Kit

A toolkit that automates creating formally verified mathematical constructions using Claude Code and Lean4/Mathlib. Specify a domain + required properties, and an agent pipeline proposes a mathematical construction, then iteratively proves it correct via `lake build` cycles.

## Prerequisites

- **elan** / **Lean4**: Install via `curl https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh -sSf | sh`
- **Claude Code**: `npm install -g @anthropic-ai/claude-code`
- **gh CLI** (optional): For the LOG phase PR creation

## Installation

```bash
cd your-lean-project
/path/to/claude-mathematics-kit/install.sh
```

The installer will:
1. Copy all kit files (safe, won't overwrite existing)
2. Check for `lake` / `elan` toolchain
3. Initialize a Lean4+Mathlib project if no lakefile exists
4. Run `lake update` to fetch Mathlib
5. Verify `lake build` succeeds
6. Create `specs/` and `results/` directories

## 7-Phase Pipeline

```
SURVEY → SPECIFY → CONSTRUCT → FORMALIZE → PROVE → AUDIT → LOG
  │         │          │           │          │        │      │
  │         │          │           │          │        │      └─ git commit + PR
  │         │          │           │          │        └─ .lean files LOCKED, review coverage
  │         │          │           │          └─ spec LOCKED, fill in sorrys via lake build loop
  │         │          │           └─ write .lean defs + theorems (all sorry)
  │         │          └─ informal math: definitions, theorems, proof sketches
  │         └─ precise property requirements (no Lean4 syntax)
  └─ survey Mathlib, domain literature, existing formalizations
```

### Phase Details

| Phase | Agent | Writes | Reads | Enforcement |
|-------|-------|--------|-------|-------------|
| **SURVEY** | Domain Surveyor | nothing (read-only) | Mathlib, specs, project | No file writes |
| **SPECIFY** | Spec Writer | `specs/*.md`, `DOMAIN_CONTEXT.md` | survey output | No `.lean` code |
| **CONSTRUCT** | Mathematician | `specs/construction-*.md` | specs, domain context | No `.lean` code |
| **FORMALIZE** | Lean4 Expert | `.lean` files (all `sorry`) | specs, construction docs | No real proofs |
| **PROVE** | Proof Engineer | `.lean` proofs (Edit only) | specs (locked), `.lean` | Spec is `chmod 444` |
| **AUDIT** | Auditor | `CONSTRUCTION_LOG.md`, `REVISION.md` | everything (locked) | `.lean` files `chmod 444` |
| **LOG** | — | git commit + PR | — | — |

## Usage

### Individual Phases
```bash
./math.sh survey    specs/my-construction.md
./math.sh specify   specs/my-construction.md
./math.sh construct specs/my-construction.md
./math.sh formalize specs/my-construction.md
./math.sh prove     specs/my-construction.md
./math.sh audit     specs/my-construction.md
./math.sh log       specs/my-construction.md
```

### Full Pipeline
```bash
./math.sh full specs/my-construction.md
```

Runs all 7 phases with automatic revision loop support.

### Program Mode
```bash
# Edit CONSTRUCTIONS.md with your construction queue
./math.sh program
./math.sh program --max-cycles 10
```

Auto-advances through constructions listed in `CONSTRUCTIONS.md`.

### Utilities
```bash
./math.sh status                    # Sorry count, axiom count, build status
./math.sh watch prove               # Live-tail the prove phase
./math.sh watch prove --resolve     # One-shot summary
./math.sh watch prove --verbose     # Show build output
```

### Aliases
```bash
source math-aliases.sh
math-status                         # Quick status
math-sorrys                         # Sorry count per file
math-axioms                         # Scan for axiom/unsafe/native_decide
math-unlock                         # Emergency: restore file permissions
```

## Defense-in-Depth (3 Layers)

| Layer | Mechanism | What it enforces |
|-------|-----------|------------------|
| **Prompts** | Phase-specific system prompts | Agent "wants" to stay in role |
| **OS permissions** | `chmod 444` on specs (PROVE) and `.lean` files (AUDIT) | OS blocks writes even if agent tries |
| **Hook** | `.claude/hooks/pre-tool-use.sh` | Blocks `axiom`, `unsafe`, `native_decide`, `chmod`/`sudo`, `git revert`, phase-specific writes |

### Universal Blocks (All Phases)
- `axiom` declarations
- `unsafe` code
- `native_decide` usage
- `admit` usage
- `chmod` / `sudo` / permission changes
- Destructive git commands (`revert`, `checkout`, `restore`, `stash`, `reset`)

## Revision Cycles

If the PROVE or AUDIT phase discovers the construction is unprovable, the agent creates `REVISION.md` with:
- `restart_from:` — which phase to restart from (CONSTRUCT or FORMALIZE)
- Problem description and evidence
- Suggested fix

The `full` pipeline automatically handles up to `MAX_REVISIONS` (default: 3) revision cycles. Previous attempts are archived in `results/revisions/`.

## Configuration

Environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `LEAN_DIR` | `.` | Lean4 project root |
| `SPEC_DIR` | `specs` | Spec & construction docs directory |
| `LAKE_BUILD` | `lake build` | Build command |
| `MAX_REVISIONS` | `3` | Max revision cycles per construction |
| `MAX_PROGRAM_CYCLES` | `20` | Max cycles in program mode |
| `MATH_AUTO_MERGE` | `false` | Auto-merge PR after creation |
| `MATH_BASE_BRANCH` | `main` | Base branch for PRs |

## File Structure

```
your-project/
├── math.sh                           # Main orchestrator
├── math-aliases.sh                   # Shell aliases
├── CLAUDE.md                         # Workflow instructions for Claude
├── CONSTRUCTIONS.md                  # Program-mode queue
├── CONSTRUCTION_LOG.md               # Audit trail
├── DOMAIN_CONTEXT.md                 # Domain knowledge + Mathlib mappings
├── specs/                            # Spec & construction docs
│   ├── my-construction.md
│   └── construction-my-construction.md
├── results/                          # Archived results
│   └── my-construction/
├── scripts/
│   └── math-watch.py                 # Live monitoring
├── templates/
│   └── construction-spec.md          # Spec template
├── .claude/
│   ├── settings.json                 # Hook registration
│   ├── hooks/
│   │   └── pre-tool-use.sh           # Multi-phase enforcement
│   └── prompts/
│       ├── math-survey.md
│       ├── math-specify.md
│       ├── math-construct.md
│       ├── math-formalize.md
│       ├── math-prove.md
│       └── math-audit.md
└── lakefile.lean                     # Lean4 project config
```
