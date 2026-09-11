# LLMCOBOL

**Date:** 2026-07-31

**License:** Apache License, Version 2.0 — <https://www.apache.org/licenses/LICENSE-2.0>

**Authors:** Jack Woehr \<<jwoehr@softwoehr.com>\>, IBM Bob (AI pair programmer)

**Thanks:** Patrick Behr \<<pbehr@behrbros.com>\>

---

## Purpose

`LLMCOBOL` is a demonstration project for the
[IBM AI-SDK-Db2-IBMi](https://github.com/IBM/AI-SDK-Db2-IBMi) library.
It provides an interactive 5250 green-screen application for IBM i that lets
a user query large language models (LLMs) directly from a traditional terminal
session. The program supports both a local **Ollama** backend and any
**OpenAI-compatible** REST endpoint (including Google Gemini via its OpenAI
compatibility layer). Connection parameters (protocol, server, port, model,
API key, base path) can be configured interactively and saved as per-user
defaults via the IBM i data area facility.

The project depends on the `DBSDK_V1` library from the IBM AI-SDK-Db2-IBMi,
which supplies the SQL scalar functions used to call LLM endpoints.

---

## Project Layout

```text
src/LLMCOBOL/
├── README.md                        This file
├── Makefile                         Build script — compiles DSPF and SQLCBLLE on IBM i
├── LLMDSPF.DSPF                     DDS display file — all 5250 screen definitions
└── LLMCOBOL.SQLCBLLE                ILE COBOL program — main application logic
```

---

## Files

### [`LLMCOBOL.SQLCBLLE`](LLMCOBOL.SQLCBLLE)

ILE COBOL (SQL-enabled) program. This is the main application.
It presents the user with a prompt/response screen, manages backend
configuration (Ollama and OpenAI-compatible), stores defaults in IBM i data
areas, and calls the `DBSDK_V1` SQL functions to submit prompts and retrieve
responses from the configured LLM endpoint.

Key procedures:

| Procedure | Purpose |
| --- | --- |
| [`FETCH-CONFIG`](LLMCOBOL.SQLCBLLE:364) | Reads configuration from a backend-specific data area |
| [`SET-FOR-JOB`](LLMCOBOL.SQLCBLLE:414) | Applies configuration to the current job's data area |
| [`SET-MY-DEFAULTS`](LLMCOBOL.SQLCBLLE:464) | Saves configuration as the user's default data area |
| [`EDIT-CONFIG`](LLMCOBOL.SQLCBLLE:514) | Backend selector config screen |
| [`EDIT-OLLAMA-CONFIG`](LLMCOBOL.SQLCBLLE:580) | Ollama-specific configuration sub-screen |
| [`EDIT-OAI-CONFIG`](LLMCOBOL.SQLCBLLE:683) | OpenAI-compatible configuration sub-screen |
| [`PROMPT-FIELD`](LLMCOBOL.SQLCBLLE:814) | F4-prompt subfile for field value selection |
| [`CALL-LLM`](LLMCOBOL.SQLCBLLE:1025) | Submits the prompt via embedded SQL to `DBSDK_V1` functions |
| [`SEND-PROGRAM-MESSAGE`](LLMCOBOL.SQLCBLLE:1102) | Sends a message to the program message queue |
| [`CLEAR-PROGRAM-MESSAGES`](LLMCOBOL.SQLCBLLE:1126) | Clears the program message queue |

### [`LLMDSPF.DSPF`](LLMDSPF.DSPF)

DDS display file defining all 5250 screen records used by `LLMCOBOL`:

| Record | Purpose |
| --- | --- |
| [`RUNSCRN`](LLMDSPF.DSPF:26) | Main prompt/response screen |
| [`CFGSCRN`](LLMDSPF.DSPF:51) | Backend selector (first configuration screen) |
| [`OLLAMACFG`](LLMDSPF.DSPF:73) | Ollama-specific configuration sub-screen |
| [`OAICFG`](LLMDSPF.DSPF:118) | OpenAI-compatible configuration sub-screen |
| [`PROMPTSFL`](LLMDSPF.DSPF:167) / [`PROMPTCTL`](LLMDSPF.DSPF:173) | Subfile for F4 field-value prompting |
| [`PROMPTKEYS`](LLMDSPF.DSPF:188) | Key legend overlay for the prompt subfile |
| [`MSGSFL`](LLMDSPF.DSPF:195) / [`MSGSFLC`](LLMDSPF.DSPF:200) | Program message subfile (line 23) |

### [`Makefile`](Makefile)

GNU `make` build script intended to run in IBM i PASE. Compiles the display
file and COBOL program into an IBM i library.

```text
make [target] [TARGET_LIB=<lib>] [SOURCE_LIB=<lib>] [VERBOSE=1]

Targets:
  all     Build display file and COBOL program (default)
  dspf    Build LLMDSPF display file only
  cbl     Build LLMCOBOL SQL COBOL program only
  clean   Delete compiled objects from TARGET_LIB
  help    Show help

Options:
  TARGET_LIB=<lib>   Library to compile objects into (default: DBSDK_DEMO)
  SOURCE_LIB=<lib>   Library for DSPF staging (default: TARGET_LIB)
  VERBOSE=1          Show full compilation output
```

**Prerequisites:** `TARGET_LIB` and `SOURCE_LIB` must exist; `DBSDK_V1` must
be on the library list.

---

## Running the Program

After building with `make`:

```text
ADDLIBLE DBSDK_V1
CALL PGM(DBSDK_DEMO/LLMCOBOL)
```

Use **F4** on any configuration field to prompt for known values.
Use **F6** to save the current configuration as your personal default.
Use **F3** or **F12** to exit or cancel screens.
