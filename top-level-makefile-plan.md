# Top-level Makefile plan

## Top-level overview

Add a thin top-level [Makefile](Makefile) at the workspace root that delegates
to the two existing sub-project makefiles in [src/LLMRPG/](src/LLMRPG/Makefile)
and [src/LLMCOBOL/](src/LLMCOBOL/Makefile). The sub-makefiles are already
correct and independently usable; the top-level file adds convenience without
duplicating logic.

The approach is **delegation** (Option A): each target uses `$(MAKE) -C` to
forward the call to the relevant sub-makefile. Variable overrides such as
`TARGET_LIB=MYLIB` continue to work per-project.

---

## Sub-task 1 — Create the top-level Makefile

**Intent** Provide a single entry point that lets a developer build one or both
IBM i programs from the workspace root without changing directories.

**Expected outcomes**

- `make` or `make all` — builds LLMRPG first, then LLMCOBOL (sequential)
- `make rpg` — builds only LLMRPG (delegates to `src/LLMRPG/Makefile all`)
- `make cbl` — builds only LLMCOBOL (delegates to `src/LLMCOBOL/Makefile all`)
- `make clean` — cleans both sub-projects sequentially
- `make help` — prints a usage summary that documents `TARGET_LIB` and `VERBOSE`
  overrides with example invocations
- Each sub-project remains fully independently buildable via its own `make`
  invocation inside its directory
- Variable overrides (`TARGET_LIB`, `SOURCE_LIB`, `VERBOSE`) are forwarded
  automatically because `$(MAKE) -C` propagates command-line variables

**Todo list**

- [ ] Create [Makefile](Makefile) at the workspace root with:
  - `SHELL := /bin/bash`
  - `MAKE ?= make` (or rely on the built-in `$(MAKE)`)
  - `.PHONY: all rpg cbl clean help`
  - `all` target: depends on `rpg` then `cbl`
  - `rpg` target: `$(MAKE) -C src/LLMRPG`
  - `cbl` target: `$(MAKE) -C src/LLMCOBOL`
  - `clean` target: `$(MAKE) -C src/LLMRPG clean` then
    `$(MAKE) -C src/LLMCOBOL clean`
  - `help` target: prints usage for all four targets; explicitly documents
    `TARGET_LIB` (default `DBSDK_DEMO`) and `VERBOSE` (default `0`) with example
    override invocations such as `make rpg TARGET_LIB=MYLIB VERBOSE=1`

**Relevant context**

- [src/LLMRPG/Makefile](src/LLMRPG/Makefile) — existing RPG sub-makefile;
  default target is `all`
- [src/LLMCOBOL/Makefile](src/LLMCOBOL/Makefile) — existing COBOL sub-makefile;
  default target is `all`
- Both share `TARGET_LIB ?= DBSDK_DEMO` as the default library name

**Status:** `[ ] pending`
