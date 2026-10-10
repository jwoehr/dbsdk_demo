#===============================================================================
# Top-level Makefile — LLM Backend Selection Demo
#===============================================================================
# Delegates to the individual sub-project makefiles.  Each sub-project can
# still be built independently by running make inside its own directory.
#
# Usage: make [target] [TARGET_LIB=<lib>] [VERBOSE=1]
#   make all    - Build LLMRPG, LLMCOBOL, and LLMRPGAGT (default)
#   make rpg    - Build LLMRPG only
#   make cbl    - Build LLMCOBOL only
#   make agt    - Build LLMRPGAGT only
#   make clean  - Clean all sub-projects
#   make help   - Show this help message
#
# Options:
#   TARGET_LIB=<lib>  - Library to compile objects into (default: DBSDK_DEMO)
#   SOURCE_LIB=<lib>  - Library for DSPF staging (default: same as TARGET_LIB)
#   VERBOSE=1         - Show full compilation output (default: suppressed)
#===============================================================================

SHELL := /bin/bash

.PHONY: all rpg cbl agt clean help

#-------------------------------------------------------------------------------
# Default target — sequential: RPG, COBOL, then Agent
#-------------------------------------------------------------------------------
all: rpg cbl agt

#-------------------------------------------------------------------------------
# Per-project targets
#-------------------------------------------------------------------------------
rpg:
	$(MAKE) -C src/LLMRPG

cbl:
	$(MAKE) -C src/LLMCOBOL

agt:
	$(MAKE) -C src/LLMRPGAGT

#-------------------------------------------------------------------------------
# Clean all sub-projects
#-------------------------------------------------------------------------------
clean:
	$(MAKE) -C src/LLMRPG clean
	$(MAKE) -C src/LLMCOBOL clean
	$(MAKE) -C src/LLMRPGAGT clean

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
help:
	@printf "Top-level Makefile — LLM Backend Selection Demo\n\n"
	@printf "Usage: make [target] [TARGET_LIB=<lib>] [VERBOSE=1]\n\n"
	@printf "Targets:\n"
	@printf "  all    - Build LLMRPG, LLMCOBOL, and LLMRPGAGT sequentially (default)\n"
	@printf "  rpg    - Build LLMRPG only\n"
	@printf "  cbl    - Build LLMCOBOL only\n"
	@printf "  agt    - Build LLMRPGAGT only\n"
	@printf "  clean  - Delete compiled objects from TARGET_LIB in all projects\n"
	@printf "  help   - Show this help\n\n"
	@printf "Options:\n"
	@printf "  TARGET_LIB=<lib>  Library to compile into (default: DBSDK_DEMO)\n"
	@printf "  SOURCE_LIB=<lib>  Library for DSPF staging (default: TARGET_LIB)\n"
	@printf "  VERBOSE=1         Show full cl/system output\n\n"
	@printf "Examples:\n"
	@printf "  make\n"
	@printf "  make rpg TARGET_LIB=MYLIB VERBOSE=1\n"
	@printf "  make cbl TARGET_LIB=MYLIB\n"
	@printf "  make agt TARGET_LIB=MYLIB\n"
	@printf "  make clean TARGET_LIB=MYLIB\n"

# Made with Bob
