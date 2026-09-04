# dbsdk_demo

**Date:** 2025-07-31

**License:** Apache License, Version 2.0 — <https://www.apache.org/licenses/LICENSE-2.0>

**Authors:** Jack Woehr \<<jwoehr@softwoehr.com>\>, IBM Bob (AI pair programmer)

**Thanks:** Patrick Behr \<<pbehr@behrbros.com>\>

---

## Purpose

`dbsdk_demo` is a demonstration project for the
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
dbsdk_demo/
├── README.md                        This file
├── LICENSE                          Apache 2.0 license text
├── llmrpg-plan.md                   Design notes and planning document
└── src/
    └── LLMRPG/
        ├── Makefile                 Build script — compiles DSPF and SQLRPGLE on IBM i
        ├── LLMDSPF.DSPF             DDS display file — all 5250 screen definitions
        ├── LLMRPG.SQLRPGLE          ILE RPG program — main application logic
        └── gemini_openai_compat.sh  Shell example — curl call to Gemini OpenAI-compat API
```

---

## Files

### `src/LLMRPG/LLMRPG.SQLRPGLE`

ILE RPG (free-format, SQL-enabled) program. This is the main application.
It presents the user with a prompt/response screen, manages backend
configuration (Ollama and OpenAI-compatible), stores defaults in IBM i data
areas, and calls the `DBSDK_V1` SQL functions to submit prompts and retrieve
responses from the configured LLM endpoint.

Key procedures:

| Procedure | Purpose |
| --- | --- |
| `fetchConfig` | Reads configuration from a backend-specific data area |
| `setForJob` | Applies configuration to the current job's data area |
| `setMyDefaults` | Saves configuration as the user's default data area |
| `editConfig` | Backend selector config screen |
| `editOllamaConfig` | Ollama-specific configuration sub-screen |
| `editOAIConfig` | OpenAI-compatible configuration sub-screen |
| `promptField` | F4-prompt subfile for field value selection |
| `callLLM` | Submits the prompt via embedded SQL to `DBSDK_V1` functions |
| `SendProgramMessage` | Sends a message to the program message queue |
| `ClearProgramMessages` | Clears the program message queue |

### `src/LLMRPG/LLMDSPF.DSPF`

DDS display file defining all 5250 screen records used by `LLMRPG`:

| Record | Purpose |
| --- | --- |
| `RUNSCRN` | Main prompt/response screen |
| `CFGSCRN` | Backend selector (first configuration screen) |
| `OLLAMACFG` | Ollama-specific configuration sub-screen |
| `OAICFG` | OpenAI-compatible configuration sub-screen |
| `PROMPTSFL` / `PROMPTCTL` | Subfile for F4 field-value prompting |
| `PROMPTKEYS` | Key legend overlay for the prompt subfile |
| `MSGSFL` / `MSGSFLC` | Program message subfile (line 23) |

### `src/LLMRPG/Makefile`

GNU `make` build script intended to run in IBM i PASE. Compiles the display
file and RPG program into an IBM i library.

```text
make [target] [TARGET_LIB=<lib>] [SOURCE_LIB=<lib>] [VERBOSE=1]

Targets:
  all     Build display file and RPG program (default)
  dspf    Build LLMDSPF display file only
  rpgle   Build LLMRPG SQL RPG program only
  clean   Delete compiled objects from TARGET_LIB
  help    Show help

Options:
  TARGET_LIB=<lib>   Library to compile objects into (default: DBSDK_DEMO)
  SOURCE_LIB=<lib>   Library for DSPF staging (default: TARGET_LIB)
  VERBOSE=1          Show full compilation output
```

**Prerequisites:** `TARGET_LIB` and `SOURCE_LIB` must exist; `DBSDK_V1` must
be on the library list.

### `src/LLMRPG/gemini_openai_compat.sh`

Shell script illustrating a direct `curl` call to the Google Gemini API using
its OpenAI-compatibility endpoint. Useful as a quick connectivity test before
configuring `LLMRPG` to use `openai_compatible` mode against Gemini.
Requires the environment variable `GEMINI_API_KEY` to be set.
See <https://ai.google.dev/gemini-api/docs/openai> for details.

---

## Running the Program

After building with `make`:

```text
ADDLIBLE DBSDK_V1
CALL PGM(DBSDK_DEMO/LLMRPG)
```

Use **F4** on any configuration field to prompt for known values.
Use **F6** to save the current configuration as your personal default.
Use **F3** or **F12** to exit or cancel screens.
