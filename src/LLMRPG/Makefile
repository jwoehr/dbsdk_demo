#===============================================================================
# LLMRPG - LLM Backend Selection Demo
#===============================================================================
# Compiles LLMDSPF.DSPF and LLMRPG.SQLRPGLE from the IFS into an IBM i library.
# The DSPF is staged through a source physical file (QDDSSRC) in SOURCE_LIB.
# QTEMP cannot be used for staging because CPYFRMSTMF requires a real library
# addressable via /QSYS.LIB/<lib>.LIB/... from a PASE multithreaded job.
#
# Usage: make [target] [TARGET_LIB=<lib>] [SOURCE_LIB=<lib>] [VERBOSE=1]
#   make all     - Build display file and RPG program (default)
#   make dspf    - Build display file only
#   make rpgle   - Build RPG program only
#   make clean   - Delete compiled objects from TARGET_LIB
#   make help    - Show this help message
#
# Options:
#   TARGET_LIB=<lib>  - Library to compile objects into (default: DBSDK_DEMO)
#   SOURCE_LIB=<lib>  - Library for DSPF staging (default: same as TARGET_LIB)
#   VERBOSE=1         - Show full compilation output (default: suppressed)
#
# Prerequisites:
#   - TARGET_LIB library must exist
#   - SOURCE_LIB library must exist (defaults to TARGET_LIB)
#   - DBSDK_V1 library must be on the library list (contains SQL functions)
#   - IBM i PASE commands cl and system must be available in PATH
#===============================================================================

SHELL := /bin/bash

# Verbose mode — set VERBOSE=1 on the make command line to see full output
VERBOSE ?= 0
ifeq ($(VERBOSE),1)
    REDIRECT :=
else
    REDIRECT := > /dev/null 2>&1
endif

# Color codes
RED    := \033[0;31m
GREEN  := \033[0;32m
YELLOW := \033[1;33m
BLUE   := \033[0;34m
NC     := \033[0m

# Directory containing this Makefile (absolute, resolved at make time)
BASE_DIR := $(shell pwd)

# Library that receives the compiled objects
TARGET_LIB ?= DBSDK_DEMO

# Library used to stage the DSPF source member before compilation.
# Must be a real persistent library addressable via /QSYS.LIB/<lib>.LIB/...
# QTEMP cannot be used here — its IFS path is not valid from a PASE
# multithreaded job (CPYFRMSTMF requires a resolvable IFS destination).
SOURCE_LIB ?= $(TARGET_LIB)
STAGE_FILE  := QDDSSRC

# Source members
DSPF_NAME  := LLMDSPF
RPGLE_NAME := LLMRPG

.PHONY: all dspf rpgle clean help

#-------------------------------------------------------------------------------
# Default target
#-------------------------------------------------------------------------------
all: header dspf rpgle summary

#-------------------------------------------------------------------------------
# Header / summary
#-------------------------------------------------------------------------------
header:
	@printf "$(BLUE)============================================================$(NC)\n"
	@printf "$(BLUE) LLMRPG build  ->  $(TARGET_LIB)$(NC)\n"
	@printf "$(BLUE)============================================================$(NC)\n"

summary:
	@printf "$(GREEN)✓ Build complete.$(NC)\n"
	@printf "  To run: CALL PGM($(TARGET_LIB)/$(RPGLE_NAME))\n"

#-------------------------------------------------------------------------------
# Display file
#
# Strategy:
#   1. Create a temporary source physical file in QTEMP (CRTSRCPF).
#   2. Copy the IFS stream file into a source member (CPYFRMSTMF).
#   3. Compile the display file from that member (CRTDSPF).
#   QTEMP is cleaned up automatically when the job ends.
#-------------------------------------------------------------------------------
dspf:
	@printf "$(YELLOW)>>> Compiling $(DSPF_NAME).DSPF ...$(NC)\n"
	@cl "CRTSRCPF FILE($(SOURCE_LIB)/$(STAGE_FILE)) RCDLEN(112)" $(REDIRECT) || true
	@if cl "CPYFRMSTMF FROMSTMF('$(BASE_DIR)/$(DSPF_NAME).DSPF') TOMBR('/QSYS.LIB/$(SOURCE_LIB).LIB/$(STAGE_FILE).FILE/$(DSPF_NAME).MBR') MBROPT(*REPLACE)" $(REDIRECT); then \
		if cl "CRTDSPF FILE($(TARGET_LIB)/$(DSPF_NAME)) SRCFILE($(SOURCE_LIB)/$(STAGE_FILE)) SRCMBR($(DSPF_NAME)) GENLVL(30)" $(REDIRECT); then \
			printf "$(GREEN)✓ $(DSPF_NAME) compiled successfully$(NC)\n"; \
		else \
			printf "$(RED)✗ CRTDSPF failed for $(DSPF_NAME)$(NC)\n"; \
			exit 1; \
		fi; \
	else \
		printf "$(RED)✗ CPYFRMSTMF failed for $(DSPF_NAME).DSPF$(NC)\n"; \
		exit 1; \
	fi

#-------------------------------------------------------------------------------
# SQL RPG program
#
# CRTSQLRPGI compiles directly from the IFS stream file — no staging needed.
# DFTRDBCOL(DBSDK_V1) makes unqualified SQL names resolve to DBSDK_V1.
# CVTCCSID(*JOB) handles UTF-8 source files.
# SQLPATH(*LIBL) resolves SQL function/procedure names via the library list.
# ADDLIBLE for both TARGET_LIB and DBSDK_V1 must run before CRTSQLRPGI so
# the precompiler inherits a library list that includes the compiled DSPF
# (TARGET_LIB/LLMDSPF) and the SQL function definitions (DBSDK_V1).
# GENLVL(20) allows the compile to succeed despite severity-10 warnings about
# config tables (OLLAMA_CONFIG_*) that may not yet be installed.
#-------------------------------------------------------------------------------
rpgle:
	@printf "$(YELLOW)>>> Compiling $(RPGLE_NAME).SQLRPGLE ...$(NC)\n"
	@bash -c 'cl "ADDLIBLE $(TARGET_LIB)" $(REDIRECT); cl "ADDLIBLE DBSDK_V1" $(REDIRECT); cl "CRTSQLRPGI OBJ($(TARGET_LIB)/$(RPGLE_NAME)) SRCSTMF('"'"'$(BASE_DIR)/$(RPGLE_NAME).SQLRPGLE'"'"') COMMIT(*NONE) DBGVIEW(*SOURCE) COMPILEOPT('"'"'DFTACTGRP(*NO) ACTGRP(*NEW) TGTCCSID(*JOB)'"'"') USRPRF(*OWNER) RDB(*LOCAL) DFTRDBCOL(DBSDK_V1) CVTCCSID(*JOB) SQLPATH(*LIBL) GENLVL(20)" $(REDIRECT)' && \
		printf "$(GREEN)✓ $(RPGLE_NAME) compiled successfully$(NC)\n" || \
		{ printf "$(RED)✗ CRTSQLRPGI failed for $(RPGLE_NAME)$(NC)\n"; exit 1; }

#-------------------------------------------------------------------------------
# Clean — delete compiled objects from TARGET_LIB
#-------------------------------------------------------------------------------
clean:
	@printf "$(YELLOW)Deleting $(DSPF_NAME) and $(RPGLE_NAME) from $(TARGET_LIB) ...$(NC)\n"
	@cl "DLTF FILE($(TARGET_LIB)/$(DSPF_NAME))" $(REDIRECT) || true
	@cl "DLTPGM PGM($(TARGET_LIB)/$(RPGLE_NAME))" $(REDIRECT) || true
	@printf "$(GREEN)✓ Clean complete$(NC)\n"

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
help:
	@printf "LLMRPG Makefile\n\n"
	@printf "Usage: make [target] [TARGET_LIB=<lib>] [VERBOSE=1]\n\n"
	@printf "Targets:\n"
	@printf "  all    - Build display file and RPG program (default)\n"
	@printf "  dspf   - Build $(DSPF_NAME) display file only\n"
	@printf "  rpgle  - Build $(RPGLE_NAME) SQL RPG program only\n"
	@printf "  clean  - Delete compiled objects from TARGET_LIB\n"
	@printf "  help   - Show this help\n\n"
	@printf "Options:\n"
	@printf "  TARGET_LIB=<lib>  Library to compile into (default: DBSDK_DEMO)\n"
	@printf "  SOURCE_LIB=<lib>  Library for DSPF staging (default: TARGET_LIB)\n"
	@printf "  VERBOSE=1         Show full cl/system output\n\n"
	@printf "Examples:\n"
	@printf "  make\n"
	@printf "  make TARGET_LIB=MYLIB\n"
	@printf "  make TARGET_LIB=MYLIB SOURCE_LIB=JWOEHR\n"
	@printf "  make dspf VERBOSE=1\n"
	@printf "  make clean TARGET_LIB=MYLIB\n"

# Made with Bob
