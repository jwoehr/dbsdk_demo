# LLMRPG Plan

## This plan is historical

IBM Bob prepared this plan. Many details of the screen layout have changed.
This document preserved here for insight into IBM Bob.

## Top-Level Overview

Create a new 5250 RPG application `LLMRPG` in `dbsdk_demo/src/LLMRPG/` that extends the pattern of
`NEUGC/2026/code/OLLAMARPG` to support two AI backends selectable at runtime:

- **ollama** — calls `dbsdk_v1.ollama_generate()` via the ollama utils (protocol, server, port, model)
- **openai_compatible** — calls `dbsdk_v1.openai_compatible_generate()` via the openai_compatible utils
  (protocol, server, port, model, api key, base path)

The application consists of two source members:
- `dbsdk_demo/src/LLMRPG/LLMDSPF.DSPF` — display file with all screens
- `dbsdk_demo/src/LLMRPG/LLMRPG.SQLRPGLE` — free-format SQL RPG program

**Key design decisions:**
- Backend is selected as the first field on the config screen (F4 from run screen), with F4 prompt listing `ollama` and `openai_compatible`
- Ollama config and openai_compatible config are **separate sub-screens** shown depending on the chosen backend
- API key is shown as `********` if the user leaves the configured default; the actual stored value is kept in a hidden field
- Base path is shown with the current configured value (defaulting to `/v1`) and is editable
- The main run screen shows the current backend, URL, and model — matching OLLAMARPG's RUN screen style
- All config getter/setter procedure calls follow the existing `dbsdk_v1.*` naming convention
- Message handling (SendProgramMessage / ClearProgramMessages) and subfile prompt pattern are copied verbatim from OLLAMARPG

---

## Sub-Tasks

---

### Sub-Task 1 — Display File (`LLMDSPF.DSPF`)

**Intent:** Define all 5250 screen records needed by the application.

**Expected Outcomes:** A compilable DDS source member with all records the RPG program will reference.

**Todo List:**
1. Define file-level attributes: `DSPSIZ(24 80 *DS3)`, `INDARA`, all CA/CF keys (matching OLLAMARPG)
2. Define `RUNSCRN` record — OVERLAY, showing:
   - Row 3: `Backend:` label + `RUN_BKND` (20A output)
   - Row 4: `URL:` label + `RUN_URL` (70A output)
   - Row 5: `Model:` label + `RUN_MODL` (70A output)
   - Row 7: `Prompt:` label + `PROMPT` (500A B, WRDWRAP, CHECK(LC))
   - Row 15: `Resp:` label + `RESPONSE` (500A B, WRDWRAP)
   - Row 22: `F3=Exit  F4=Config` (BLU)
3. Define `CFGSCRN` record — OVERLAY, RTNCSRLOC(&CURREC &CURFLD):
   - Hidden fields `CURREC` (10A) and `CURFLD` (10A)
   - Row 4: `Backend:` label + `CFG_BKND` (20A B, CHECK(LC), CHANGE(30), indicator 20 for protect)
   - Row 22: `F12=Cancel  F6=Make My Default  Enter=Use these values` (BLU)
4. Define `OLLAMACFG` record — OVERLAY, for ollama-specific config fields:
   - Row 6: `Protocol:` + `OL_PROT` (10A B, CHECK(LC), CHANGE(31), indicator 21 protect)
   - Row 8: `Server:` + `OL_SRVRH` (1000A H), `OL_SRVR` (227A B, CHECK(LC), CHANGE(32), indicator 22 protect)
   - Row 12: `Port:` + `OL_PORT` (10 numeric B, CHECK(LC), CHANGE(33), indicator 23 protect)
   - Row 14: `Model:` + `OL_MODLH` (1000A H), `OL_MODL` (227A B, CHECK(LC), CHANGE(34), indicator 24 protect)
   - Row 22: `F12=Cancel  F6=Make My Default  Enter=Use these values` (BLU)
5. Define `OAICFG` record — OVERLAY, for openai_compatible-specific config fields:
   - Row 6: `Protocol:` + `OA_PROT` (10A B, CHECK(LC), CHANGE(31), indicator 21 protect)
   - Row 8: `Server:` + `OA_SRVRH` (1000A H), `OA_SRVR` (227A B, CHECK(LC), CHANGE(32), indicator 22 protect)
   - Row 12: `Port:` + `OA_PORT` (10 numeric B, CHECK(LC), CHANGE(33), indicator 23 protect)
   - Row 14: `Model:` + `OA_MODLH` (1000A H), `OA_MODL` (227A B, CHECK(LC), CHANGE(34), indicator 24 protect)
   - Row 16: `API Key:` + `OA_KEYH` (8000A H), `OA_KEY` (40A B, CHECK(LC), CHANGE(35), indicator 25 protect)
   - Row 18: `Base Path:` + `OA_PATH` (227A B, CHECK(LC), CHANGE(36), indicator 26 protect)
   - Row 22: `F12=Cancel  F6=Make My Default  Enter=Use these values` (BLU)
6. Define `PROMPTSFL` / `PROMPTCTL` / `PROMPTKEYS` subfile records — identical to OLLAMARPG
7. Define `MSGSFL` / `MSGSFLC` message subfile records — identical to OLLAMARPG

**Relevant Context:**
- [`NEUGC/2026/code/OLLAMARPG/OLLAMADSPF.DSPF`](2026/code/OLLAMARPG/OLLAMADSPF.DSPF) — copy structure verbatim, extend for new records
- Indicator assignments must not overlap: 20=backend protect, 21-24=shared field protect, 25=apikey protect, 26=basepath protect, 30-36=change indicators

**Status:** [x] done

---

### Sub-Task 2 — RPG Program Global Declarations and Main Loop (`LLMRPG.SQLRPGLE`)

**Intent:** Set up the RPG source file skeleton: file declaration, data structures, constants, global variables, SQL options, and the main `dou F3` loop mirroring OLLAMARPG's mainline.

**Expected Outcomes:** The file exists with compilable declarations and a functional main loop that calls `fetchConfig()`, `setForJob()`, displays `RUNSCRN`, and routes F3/F4/ENTER correctly.

**Todo List:**
1. Declare `LLMDSPF` workstn file with `infds`, `indds`, and `sfile(PROMPTSFL : rrn1)`
2. Declare `dspf_info` (keyPressed at pos 369) and `dspf_inds` data structures — add indicators for all new fields (positions 20-26 for protect, 30-36 for change, matching the DSPF)
3. Declare `PSDS` for `pgmName`
4. Declare function key constants F3, F4, F6, F12, ENTER (same hex values as OLLAMARPG)
5. Declare global variables: `backend` (varchar 20), `protocol` (varchar 10), `server` (varchar 1000), `port` (int 10), `model` (varchar 1000), `apikey` (varchar 8000), `basepath` (varchar 1000)
6. Set SQL options: `COMMIT=*NONE, DATFMT=*ISO, NAMING=*SYS`
7. Write mainline: call `fetchConfig()`, `setForJob()`, enter `dou F3` loop showing `RUNSCRN`, routing to `editConfig()` on F4 and `callLLM(PROMPT)` on ENTER; set `*inlr=*on` on exit

**Relevant Context:**
- [`NEUGC/2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE`](2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE) lines 1–85 — direct model
- `RUN_BKND` must be populated in the loop before `exfmt RUNSCRN`

**Status:** [x] done

---

### Sub-Task 3 — `fetchConfig()` and `setForJob()` procedures

**Intent:** Implement the configuration fetch and job-level set procedures that drive the global variables, routing to the correct `dbsdk_v1` functions based on the current `backend` value.

**Expected Outcomes:** Calling `fetchConfig()` populates all global variables from the configured defaults for whichever backend is active. Calling `setForJob()` pushes those values back into the SQL global variables for the active backend.

**Todo List:**
1. Implement `fetchConfig()`:
   - Always fetch `backend` from a persistent source. Since neither `dbsdk_v1` SDK stores a "backend" preference, store/retrieve the backend choice using the existing `dbsdk_v1.conf` table or default to `'ollama'` if none is set. (Simplest approach: use a job-level global variable `dcl-s currentBackend varchar(20)` initialised to `'ollama'`; `fetchConfig` reads from whichever backend's getters match the current value.)
   - If `backend = 'ollama'`: call `ollama_getprotocol()`, `ollama_getserver()`, `ollama_getport()`, `ollama_getmodel()`
   - If `backend = 'openai_compatible'`: call `openai_compatible_getprotocol()`, `openai_compatible_getserver()`, `openai_compatible_getport()`, `openai_compatible_getmodel()`, `openai_compatible_getapikey()`, `openai_compatible_getbasepath()`
   - Mask the API key: if `apikey` is not blank, set the display variable to `'********'`
2. Implement `setForJob()`:
   - If `backend = 'ollama'`: call `OLLAMA_SetProtocolForJob`, `OLLAMA_SetServerForJob`, `OLLAMA_SetPortForJob`, `OLLAMA_SetModelForJob`
   - If `backend = 'openai_compatible'`: call `openai_compatible_setprotocolforjob`, `openai_compatible_setserverforjob`, `openai_compatible_setportforjob`, `openai_compatible_setmodelforjob`, `openai_compatible_setapikeyforjob`, `openai_compatible_setbasepathforjob`
   - Send message "Job defaults have been set." (matching OLLAMARPG)

**Relevant Context:**
- [`AI-SDK-Db2-IBMi/src/ollama/utils.sql`](/home/jwoehr/work/AI/AI-SDK-Db2-IBMi/src/ollama/utils.sql) — ollama getters/setters
- [`AI-SDK-Db2-IBMi/src/openai_compatible/utils.sql`](/home/jwoehr/work/AI/AI-SDK-Db2-IBMi/src/openai_compatible/utils.sql) — openai_compatible getters/setters
- [`NEUGC/2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE`](2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE) lines 93–257

**Status:** [x] done

---

### Sub-Task 4 — `editConfig()` and `setMyDefaults()` procedures

**Intent:** Implement the config editing flow. The first config screen (`CFGSCRN`) lets the user select the backend; pressing ENTER then presents the backend-specific sub-screen (`OLLAMACFG` or `OAICFG`). F6 saves user defaults; ENTER applies to the job.

**Expected Outcomes:** User can change backend and all its parameters interactively. F4 on each field shows a prompt subfile. F6 persists to user defaults. ENTER sets job globals. F12 cancels.

**Todo List:**
1. Implement `editConfig()` outer loop:
   - Display `CFGSCRN` with current `backend` value in `CFG_BKND`
   - F4 on `CFG_BKND`: call `promptField('backend', ...)` with values `['ollama', 'openai_compatible']`
   - ENTER: update `backend` global, then route to `editOllamaConfig()` or `editOAIConfig()` depending on chosen backend
   - F12/F3: cancel without saving
2. Implement `editOllamaConfig()` — mirrors OLLAMARPG's `editConfig()` but uses `OL_*` fields on `OLLAMACFG` record, calls ollama setters
3. Implement `editOAIConfig()` — same structure as `editOllamaConfig()` but uses `OA_*` fields on `OAICFG` record, with extra handling:
   - `OA_KEY` display field: if user leaves it as `'********'`, do not change the stored API key (keep existing value from `apikey` global)
   - If user clears or changes `OA_KEY` from `'********'`, treat new value as the actual key
   - `OA_PATH`: editable, defaults to `/v1`
4. Implement `setMyDefaults()`:
   - If `backend = 'ollama'`: call `OLLAMA_SetProtocolForMe`, `OLLAMA_SetServerForMe`, `OLLAMA_SetPortForMe`, `OLLAMA_SetModelForMe`
   - If `backend = 'openai_compatible'`: call the equivalent `*ForMe` procedures for all 6 fields (skip API key update if display field is still `'********'`)

**Relevant Context:**
- [`NEUGC/2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE`](2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE) lines 115–257 — direct model for editConfig/setMyDefaults/setForJob

**Status:** [x] done

---

### Sub-Task 5 — `promptField()` procedure

**Intent:** Implement the F4 subfile prompt, extended to support the `'backend'` field in addition to the four ollama fields. The backend prompt is hardcoded to two values; the others pull from config tables.

**Expected Outcomes:** Pressing F4 on any editable field shows a scrollable subfile of valid values. Marking one with `1` and pressing ENTER returns the selection.

**Todo List:**
1. Copy `promptField()` from OLLAMARPG verbatim — same PI signature, same subfile logic, same cursor pattern
2. Add handling for `in_field = 'backend'`: populate `promptValues` with the two hardcoded strings `'ollama'` and `'openai_compatible'` (no SQL cursor needed — use a simple array assignment)
3. Add cursors for ollama config tables: `ollama_config_protocol`, `ollama_config_port`, `ollama_config_server`, `ollama_config_model` (same as OLLAMARPG)
4. Note: openai_compatible fields (apikey, basepath) have no config tables — they are free-entry only and F4 is not offered on those fields (the protect indicator approach handles this: simply do not set the cursor-position indicator for those fields in `editOAIConfig`)

**Relevant Context:**
- [`NEUGC/2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE`](2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE) lines 264–413

**Status:** [x] done

---

### Sub-Task 6 — `callLLM()` procedure and message utilities

**Intent:** Implement the procedure that dispatches to the correct backend's generate function based on the current `backend` global, and copy the message send/clear utilities from OLLAMARPG unchanged.

**Expected Outcomes:** Entering a prompt on the run screen calls the correct SQL function and returns the response text. SQL errors are reported as program messages.

**Todo List:**
1. Implement `callLLM(in_prompt varchar(500))` returning `varchar(1000)`:
   - Re-fetch config (sanity check, as in OLLAMARPG `callOllama`)
   - If `backend = 'ollama'`:
     - Build `prompt` JSON object `{"role":"user","content":TRIM(in_prompt)}`
     - Call `dbsdk_v1.ollama_generate(prompt => :prompt)` into a CLOB variable
     - Return first 1000 chars
   - If `backend = 'openai_compatible'`:
     - Call `dbsdk_v1.openai_compatible_generate(prompt => TRIM(:in_prompt))` into a CLOB variable
     - Return first 1000 chars
   - On `sqlcode <> 0`: call `SendProgramMessage('SQL Error: ' + %char(sqlcode))`
2. Copy `SendProgramMessage()` from OLLAMARPG verbatim (QMHSNDPM API call)
3. Copy `ClearProgramMessages()` from OLLAMARPG verbatim (QMHRMVPM API call)

**Relevant Context:**
- [`NEUGC/2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE`](2026/code/OLLAMARPG/OLLAMARPG.SQLRPGLE) lines 421–546
- [`AI-SDK-Db2-IBMi/src/ollama/generate.sql`](/home/jwoehr/work/AI/AI-SDK-Db2-IBMi/src/ollama/generate.sql) — `ollama_generate` signature: `prompt varchar(1000)`, returns `clob(2G)`
- [`AI-SDK-Db2-IBMi/src/openai_compatible/generate.sql`](/home/jwoehr/work/AI/AI-SDK-Db2-IBMi/src/openai_compatible/generate.sql) — `openai_compatible_generate` signature: `prompt varchar(32000), options varchar(32000) default '{}', api_key_ varchar(8000) default NULL, base_url varchar(1000) default NULL`, returns `clob(2G)`
- For the openai_compatible call, pass `prompt` as plain text (not JSON-wrapped), `options => '{}'`, and leave `api_key_` and `base_url` as NULL so the function uses the job-level configured values

**Status:** [x] done
