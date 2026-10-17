#===============================================================================
# LLMRPGAGT - ReAct Agent for LLM Backends
#===============================================================================
# Compiles LLMRPGAGT.SQLRPGLE from the IFS into an IBM i library.
# No display file — this is a headless HTTP server program.
#
# Usage: make [target] [TARGET_LIB=<lib>] [VERBOSE=1]
#   make all     - Build RPG program (default)
#   make rpgle   - Build RPG program only
#   make clean   - Delete compiled objects from TARGET_LIB
#   make help    - Show this help message
#
# Options:
#   TARGET_LIB=<lib>  - Library to compile objects into (default: DBSDK_DEMO)
#   VERBOSE=1         - Show full compilation output (default: suppressed)
#
# Prerequisites:
#   - TARGET_LIB library must exist
#   - DBSDK_V1 library must be on the library list (contains SQL functions)
#   - HTTPAPI (LIBHTTP binding directory) must be installed and on library list
#   - YAJL binding directory must be installed and on library list
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

# Source member names
RPGLE_NAME := LLMRPGAGT
CPP_NAME   := LLMRPGAGC
CMD_NAME   := LLMRPGAGT

.PHONY: all rpgle cmd clean help

#-------------------------------------------------------------------------------
# Default target
#-------------------------------------------------------------------------------
all: header rpgle cmd summary

#-------------------------------------------------------------------------------
# Header / summary
#-------------------------------------------------------------------------------
header:
	@printf "$(BLUE)============================================================$(NC)\n"
	@printf "$(BLUE) LLMRPGAGT build  ->  $(TARGET_LIB)$(NC)\n"
	@printf "$(BLUE)============================================================$(NC)\n"

summary:
	@printf "$(GREEN)✓ Build complete.$(NC)\n"
	@printf "  To run via CMD: $(TARGET_LIB)/$(CMD_NAME) PROVIDER('<provider>') LISTEN('<iface:port>')\n"
	@printf "  To run via CALL: CALL PGM($(TARGET_LIB)/$(RPGLE_NAME)) PARM('<provider>' '<iface:port>')\n"

#-------------------------------------------------------------------------------
# SQL RPG program
#
# CRTSQLRPGI compiles directly from the IFS stream file — no staging needed.
# DFTRDBCOL(DBSDK_V1) makes unqualified SQL names resolve to DBSDK_V1.
# CVTCCSID(*JOB) handles UTF-8 source files.
# SQLPATH(*LIBL) resolves SQL function/procedure names via the library list.
# RPGPPOPT(*LVL2) runs the RPG preprocessor in the current job, expanding
# all /COPY and /INCLUDE directives before the SQL precompiler runs. This is
# required because HTTPAPI_H contains /copy *LIBL/qrpglesrc,config_h which
# needs LIBHTTP on the library list at preprocessing time.
# All ADDLIBLE calls, CRTSQLRPGI, and CRTPGM are chained into a single
# system -K invocation (colon-separated CL commands) so the library list
# additions are in effect for both the *LVL2 preprocessor and the CRTPGM
# binding directory resolution — separate system -K calls each execute in
# their own job and do not share library list state.  cl cannot be used for
# CRTPGM because it is not safe for multithreaded jobs (the PASE shell is
# multithreaded).
# The /INCLUDE directives in the source use absolute /QSYS.LIB IFS paths so
# they resolve without any library list dependency.
# GENLVL(30) allows the compile to succeed despite severity-10/20 warnings.
#-------------------------------------------------------------------------------
rpgle: bnddir
	@printf "$(YELLOW)>>> Compiling $(RPGLE_NAME).SQLRPGLE ...$(NC)\n"
	@cl 'ADDLIBLE LIB($(TARGET_LIB))' $(REDIRECT) || true && \
	 cl 'ADDLIBLE LIB(DBSDK_V1)'     $(REDIRECT) || true && \
	 cl 'ADDLIBLE LIB(LIBHTTP)'       $(REDIRECT) || true && \
	 cl 'ADDLIBLE LIB(YAJL)'          $(REDIRECT) || true && \
	 cl 'CRTSQLRPGI OBJ($(TARGET_LIB)/$(RPGLE_NAME)) SRCSTMF('"'"'$(BASE_DIR)/$(RPGLE_NAME).SQLRPGLE'"'"') COMMIT(*NONE) DBGVIEW(*SOURCE) OBJTYPE(*MODULE) COMPILEOPT('"'"'TGTCCSID(*JOB) OPTION(*NOUNREF)'"'"') RDB(*LOCAL) DFTRDBCOL(DBSDK_V1) CVTCCSID(*JOB) SQLPATH(*LIBL) RPGPPOPT(*LVL2) GENLVL(30)' $(REDIRECT) || { printf "$(RED)✗ CRTSQLRPGI failed$(NC)\n"; exit 1; }
	@system -K 'CRTPGM PGM($(TARGET_LIB)/$(RPGLE_NAME)) MODULE($(TARGET_LIB)/$(RPGLE_NAME)) BNDDIR($(TARGET_LIB)/$(RPGLE_NAME) LIBHTTP/HTTPAPI YAJL/YAJL QC2LE) USRPRF(*OWNER) ACTGRP(*NEW) OPTION(*DUPPROC)' $(REDIRECT) || { printf "$(RED)✗ CRTPGM failed$(NC)\n"; exit 1; }
	@printf "$(GREEN)✓ $(RPGLE_NAME) compiled successfully$(NC)\n"

#-------------------------------------------------------------------------------
# Binding directory — create in TARGET_LIB with library-qualified srvpgm entries
# so the CRTSQLRPGI batch job resolves symbols without needing LIBHTTP/YAJL on
# its own library list.
# AUT(*LIBCRTAUT) allows the batch compile job user to access the bnddir.
# QC2LE is included for PASE C runtime symbols (open, write, socket, etc.).
#-------------------------------------------------------------------------------
bnddir:
	@printf "$(YELLOW)>>> Creating binding directory $(TARGET_LIB)/$(RPGLE_NAME) ...$(NC)\n"
	@system -K 'ADDLIBLE LIB($(TARGET_LIB))' $(REDIRECT) || true
	@system -K 'DLTBNDDIR BNDDIR($(TARGET_LIB)/$(RPGLE_NAME))' $(REDIRECT) || true
	@system -K 'CRTBNDDIR BNDDIR($(TARGET_LIB)/$(RPGLE_NAME)) TEXT('"'"'Binding dir for $(RPGLE_NAME)'"'"') AUT(*LIBCRTAUT)' $(REDIRECT) || { printf "$(RED)✗ Binding directory creation failed$(NC)\n"; exit 1; }
	@system -K 'ADDBNDDIRE BNDDIR($(TARGET_LIB)/$(RPGLE_NAME)) OBJ((YAJL/YAJL *SRVPGM *IMMED) (YAJL/YAJLR4 *SRVPGM *IMMED) (LIBHTTP/HTTPAPIR4 *SRVPGM *IMMED) (LIBHTTP/EXPAT *SRVPGM *IMMED))' $(REDIRECT) || { printf "$(RED)✗ ADDBNDDIRE failed$(NC)\n"; exit 1; }
	@printf "$(GREEN)✓ Binding directory created$(NC)\n"

#-------------------------------------------------------------------------------
# CL command processing program (CPP)
#-------------------------------------------------------------------------------
cpp:
	@printf "$(YELLOW)>>> Compiling $(CPP_NAME).CLLE ...$(NC)\n"
	@system -K 'ADDLIBLE LIB($(TARGET_LIB))' $(REDIRECT) || true
	@system -K 'CRTBNDCL PGM($(TARGET_LIB)/$(CPP_NAME)) SRCSTMF('"'"'$(BASE_DIR)/$(CPP_NAME).CLLE'"'"') DBGVIEW(*SOURCE) AUT(*EXCLUDE)' $(REDIRECT) || { printf "$(RED)x CRTBNDCL failed$(NC)\n"; exit 1; }
	@printf "$(GREEN)v $(CPP_NAME) compiled successfully$(NC)\n"

#-------------------------------------------------------------------------------
# Command object (*CMD)
#-------------------------------------------------------------------------------
cmd: cpp
	@printf "$(YELLOW)>>> Creating $(CMD_NAME) *CMD ...$(NC)\n"
	@system -K 'ADDLIBLE LIB($(TARGET_LIB))' $(REDIRECT) || true
	@system -K 'CRTCMD CMD($(TARGET_LIB)/$(CMD_NAME)) PGM($(TARGET_LIB)/$(CPP_NAME)) SRCSTMF('"'"'$(BASE_DIR)/$(CMD_NAME).CMD'"'"') ALLOW(*INTERACT *BATCH *BPGM *IPGM) AUT(*EXCLUDE) TEXT('"'"'Run LLMRPGAGT ReAct Agent'"'"')' $(REDIRECT) || { printf "$(RED)x CRTCMD failed$(NC)\n"; exit 1; }
	@printf "$(GREEN)v $(CMD_NAME) *CMD created successfully$(NC)\n"

#-------------------------------------------------------------------------------
# Clean - delete compiled objects from TARGET_LIB
#-------------------------------------------------------------------------------
clean:
	@printf "$(YELLOW)Deleting $(RPGLE_NAME) from $(TARGET_LIB) ...$(NC)\n"
	@system -K 'DLTCMD CMD($(TARGET_LIB)/$(CMD_NAME))' $(REDIRECT) || true
	@system -K 'DLTPGM PGM($(TARGET_LIB)/$(CPP_NAME))' $(REDIRECT) || true
	@system -K 'DLTPGM PGM($(TARGET_LIB)/$(RPGLE_NAME))' $(REDIRECT) || true
	@system -K 'DLTMOD MODULE($(TARGET_LIB)/$(RPGLE_NAME))' $(REDIRECT) || true
	@system -K 'DLTBNDDIR BNDDIR($(TARGET_LIB)/$(RPGLE_NAME))' $(REDIRECT) || true
	@printf "$(GREEN)✓ Clean complete$(NC)\n"

#-------------------------------------------------------------------------------
# Help
#-------------------------------------------------------------------------------
help:
	@printf "LLMRPGAGT Makefile\n\n"
	@printf "Usage: make [target] [TARGET_LIB=<lib>] [VERBOSE=1]\n\n"
	@printf "Targets:\n"
	@printf "  all    - Build RPG program + CPP + CMD (default)\n"
	@printf "  rpgle  - Build $(RPGLE_NAME) SQL RPG program only\n"
	@printf "  cpp    - Build $(CPP_NAME) CL command processing program only\n"
	@printf "  cmd    - Build $(CMD_NAME) *CMD (also builds CPP)\n"
	@printf "  clean  - Delete compiled objects from TARGET_LIB\n"
	@printf "  help   - Show this help\n\n"
	@printf "Options:\n"
	@printf "  TARGET_LIB=<lib>  Library to compile into (default: DBSDK_DEMO)\n"
	@printf "  VERBOSE=1         Show full cl/system output\n\n"
	@printf "Examples:\n"
	@printf "  make\n"
	@printf "  make TARGET_LIB=MYLIB\n"
	@printf "  make VERBOSE=1\n"
	@printf "  make clean TARGET_LIB=MYLIB\n"

# Made with Bob
