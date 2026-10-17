# LLMRPGAGT plan

## Top-level overview

Build `LLMRPGAGT`, a ReAct (Reason-Act) agent program in SQLRPGLE that lives in
`src/LLMRPGAGT/`. The agent runs as a persistent IBM i job that:

- Loads provider configuration from `DBSDK_V1` (identical pattern to `LLMRPG`)
- Opens an HTTP server on a caller-supplied interface and port using HTTPAPI
- Accepts `POST /query` requests carrying a JSON body with a user query
- Drives a multi-step ReAct loop: calls the LLM, decides whether to invoke a
  tool, request a clarification, or return a final answer
- Calls MCP server tools over JSON-RPC 2.0 when the LLM selects one
- Injects a Markdown skills file as a system-prompt context block at startup
- Writes a timestamped log to the IFS (default `/tmp/llmrpgagt<ts>.log`)

The program takes five positional arguments:

1. Provider name (`'ollama'` or `'openai_compatible'`) — required
2. Interface and port to serve on (e.g. `'0.0.0.0:8080'`) — required
3. MCP server URL including port (e.g. `'http://host:3000'`) — optional
4. IFS path to a Markdown skills file — optional
5. IFS path of log file — optional, default `/tmp/llmrpgagt<datetimestamp>.log`

All LLM connectivity reuses the `fetchConfig` / `setForJob` / `callLLM` pattern
from [`src/LLMRPG/LLMRPG.SQLRPGLE`](src/LLMRPG/LLMRPG.SQLRPGLE). HTTP client
calls (MCP JSON-RPC, HTTPAPI outbound) use the HTTPAPI / YAJL libraries already
referenced in the project RPG skill. Session state is held in static
in-process storage keyed by a generated session ID.

---

## Sub-task 1: Project scaffold and Makefile

**Status:** `[x] done`

### Intent

Create the `src/LLMRPGAGT/` directory structure with a `Makefile` that mirrors
[`src/LLMRPG/Makefile`](src/LLMRPG/Makefile) but compiles only a single
SQLRPGLE program (no display file). Update the top-level
[`Makefile`](Makefile) to include an `agt` target that delegates to this
sub-makefile.

### Expected outcomes

- `src/LLMRPGAGT/Makefile` exists with targets `all`, `rpgle`, `clean`, `help`
- The top-level `Makefile` gains an `agt` target and includes `LLMRPGAGT` in
  `all`
- The sub-makefile's `rpgle` target compiles
  `src/LLMRPGAGT/LLMRPGAGT.SQLRPGLE` via `CRTSQLRPGI` using the same flags as
  the LLMRPG makefile

### Todo list

- [ ] Create `src/LLMRPGAGT/Makefile` based on `src/LLMRPG/Makefile`, removing
      the `dspf` target and adjusting names to `LLMRPGAGT`
- [ ] Add `agt` phony target to top-level `Makefile` that delegates to
      `src/LLMRPGAGT/Makefile`
- [ ] Add `LLMRPGAGT` to the top-level `all` target sequence

### Relevant context

- Model: [`src/LLMRPG/Makefile`](src/LLMRPG/Makefile)
- Top-level: [`Makefile`](Makefile)

---

## Sub-task 2: Program skeleton, argument handling, and logging

**Status:** `[x] done`

### Intent

Create `src/LLMRPGAGT/LLMRPGAGT.SQLRPGLE` with the program skeleton:
control options, five parameter declarations, IFS log-file open/write/close
using prototyped PASE C APIs, and a startup banner written to the log. This
establishes the file, naming, and coding conventions all subsequent sub-tasks
will extend.

### Expected outcomes

- File `src/LLMRPGAGT/LLMRPGAGT.SQLRPGLE` exists and compiles (even though it
  does nothing yet beyond logging)
- All five parameters are declared with correct types and optionality
- Log file is opened (or created) at startup; a timestamped banner line is
  written; the file is flushed and remains open for the program lifetime
- Default log path `/tmp/llmrpgagt<YYYYMMDDHHMMSS>.log` is constructed when
  argument 5 is omitted

### Todo list

- [ ] Declare `ctl-opt` with `dftactgrp(*no)`, `actgrp(*new)`, and
      `bnddir('HTTPAPI':'YAJL')` (HTTPAPI/YAJL needed for later sub-tasks)
- [ ] Declare five `dcl-pi` parameters: `providerName varchar(20) const`,
      `listenAddr varchar(100) const`, `mcpUrl varchar(1000) const options(*omit)`,
      `skillsPath varchar(1000) const options(*omit)`,
      `logPath varchar(1000) const options(*omit)`
- [ ] Prototype PASE C `open()`, `write()`, `close()`, `fdopen()`, `fflush()`
      for IFS log writing
- [ ] Implement `openLog(path varchar(1000))` procedure: opens/creates the IFS
      file, stores the file descriptor in a module-level variable
- [ ] Implement `writeLog(msg varchar(4096))` procedure: formats a timestamp
      prefix and writes the line to the open log fd
- [ ] In mainline: construct default log path from `%timestamp()` when arg 5 is
      omitted, call `openLog`, write startup banner
- [ ] Copy `SendProgramMessage` from LLMRPG verbatim for error reporting

### Relevant context

- Pattern for `open`/`write`/`close` prototypes: standard IBM i ILE RPG PASE C
  API binding (`extproc('_C_IFS_write')` style or direct `open` from `<fcntl.h>`)
- Timestamp formatting: `%char(%timestamp() : *ISO0)` gives `YYYYMMDDHHMMSSmmm`
- Model ctl-opt and pi: [`src/LLMRPG/LLMRPG.SQLRPGLE`](src/LLMRPG/LLMRPG.SQLRPGLE:1)

---

## Sub-task 3: Provider configuration (DBSDK_V1 bootstrap)

**Status:** `[x] done`

### Intent

Port `fetchConfig` and `setForJob` from LLMRPG into LLMRPGAGT, driven by the
`providerName` argument instead of a global `backend` variable. This gives the
agent a live LLM connection before it starts serving.

### Expected outcomes

- Global variables `backend`, `protocol`, `server`, `port`, `model`, `apikey`,
  `basepath` are declared identically to LLMRPG
- `fetchConfig()` and `setForJob()` procedures are ported verbatim (using
  `backend` which is set from `providerName` on entry)
- Mainline sets `backend = providerName`, calls `fetchConfig()` then
  `setForJob()`, and logs success
- `callLLM(prompt varchar(MAX_PROMPT))` is ported, returning
  `varchar(MAX_RESPONSE)` — same logic as LLMRPG's `callLLM`

### Todo list

- [ ] Declare global LLM config variables (`backend`, `protocol`, `server`,
      `port`, `model`, `apikey`, `basepath`) matching LLMRPG types exactly
- [ ] Port `fetchConfig` procedure from LLMRPG unchanged
- [ ] Port `setForJob` procedure from LLMRPG (remove the
      `SendProgramMessage('Job defaults…')` call; log it instead)
- [ ] Port `callLLM` procedure from LLMRPG; replace `MAX_RESPONSE` constant
      (32000) and add `MAX_PROMPT` constant (4000 — larger than LLMRPG's 500
      to accommodate conversation history passed in prompts)
- [ ] In mainline: assign `backend = providerName`, call `fetchConfig()`,
      `setForJob()`, write result to log

### Relevant context

- Source to port:
  [`src/LLMRPG/LLMRPG.SQLRPGLE`](src/LLMRPG/LLMRPG.SQLRPGLE:139) lines
  139-244 (`fetchConfig`, `setForJob`) and lines 864-938 (`callLLM`)
- `MAX_RESPONSE` constant at line 76 of LLMRPG

---

## Sub-task 4: Skills file loader

**Status:** `[x] done`

### Intent

If a skills file path is provided, read the entire IFS Markdown file into a
module-level varchar variable. This string is later prepended to every LLM
system prompt. If no path is given the variable remains blank.

### Expected outcomes

- Module-level variable `skillsContent varchar(65535)` holds the file text
  after startup (or is empty if no path was given)
- File read errors are written to the log and the program continues (skills are
  advisory, not fatal)

### Todo list

- [ ] Prototype PASE C `fopen()`, `fread()`, `fclose()` for IFS stream reading
- [ ] Implement `loadSkills(path varchar(1000))` procedure: opens the file,
      reads it in chunks into `skillsContent`, closes the file, logs byte count
- [ ] In mainline: if `skillsPath` is not omitted and not blank, call
      `loadSkills(skillsPath)`

### Relevant context

- IFS file reading via `fopen`/`fread`/`fclose` C APIs prototyped in RPG
- Skills content max size: 65535 chars (single varchar — enough for a typical
  Markdown skills document; adjust constant if needed)

---

## Sub-task 5: MCP server connection and tool discovery

**Status:** `[x] done`

### Intent

At startup, if an MCP URL is provided, make a JSON-RPC 2.0 `tools/list` call
to the MCP server using HTTPAPI's outbound POST. Parse the response with
`DATA-INTO` / YAJLINTO and store the tool definitions in an in-memory array.
These tool descriptors are later formatted into the system prompt and invoked
during the ReAct loop.

### Expected outcomes

- Module-level array `mcpTools` of up to 50 tool descriptor data structures
  (name, description, input schema summary) is populated from the MCP server
- `mcpToolCount` integer records how many tools were loaded
- If the MCP URL is omitted or the call fails, `mcpToolCount = 0` and the
  agent continues without MCP tools (logged as a warning, not fatal)
- A `callMcpTool(toolName varchar(200) : toolArgs varchar(4096))` procedure is
  defined that makes a `tools/call` JSON-RPC 2.0 POST and returns the result
  string

### Todo list

- [ ] Define data structure `mcpToolDs` with fields: `toolName varchar(200)`,
      `toolDesc varchar(1000)`, `toolSchema varchar(2000)`
- [ ] Declare `mcpTools(50)` array of `likeds(mcpToolDs)` and `mcpToolCount int(10)`
- [ ] Implement `fetchMcpTools(url varchar(1000))`: POST
      `{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}` to `<url>`,
      parse response with `DATA-INTO`/YAJLINTO, populate `mcpTools` array
- [ ] Implement `callMcpTool(url varchar(1000) : toolName varchar(200) :
      toolArgs varchar(4096)) varchar(MAX_RESPONSE)`: POST
      `{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"<name>","arguments":<args>}}`
      to `<url>`, return result content string
- [ ] In mainline: if `mcpUrl` is not omitted and not blank, call
      `fetchMcpTools(mcpUrl)`, log tool count

### Relevant context

- HTTPAPI outbound POST pattern from RPG skill:
  `HTTP_String('POST' : url : %Addr(body)+2 : %Len(body) : 'application/json')`
- YAJLINTO parse: `Data-Into ds %Data(response : 'case=any allowextra=yes') %Parser('YAJLINTO')`
- MCP JSON-RPC 2.0 spec: `tools/list` returns `{"result":{"tools":[{"name":...,"description":...,"inputSchema":...}]}}`

---

## Sub-task 6: System prompt builder

**Status:** `[x] done`

### Intent

Before the HTTP server loop starts, assemble the static system prompt that will
be prepended to every LLM call. It combines: (a) the agent role description,
(b) the skills file content if loaded, (c) the MCP tool list formatted as a
tool-use instruction block.

### Expected outcomes

- Module-level `systemPrompt varchar(65535)` is populated once at startup
- The prompt instructs the LLM to reason step-by-step (ReAct pattern): output
  either a `THOUGHT:` / `ACTION:` / `ACTION_INPUT:` block to invoke a tool, a
  `CLARIFY:` block to request clarification, or `ANSWER:` for a final response
- MCP tool names and descriptions are listed in the prompt so the LLM knows
  what tools are available
- Skills content is appended after the role/tool section

### Todo list

- [ ] Define the static role preamble as a named constant or procedure that
      returns the ReAct instruction text (THOUGHT/ACTION/ACTION\_INPUT/CLARIFY/ANSWER
      grammar)
- [ ] Implement `buildSystemPrompt()` procedure: concatenates role preamble +
      MCP tool block (loop over `mcpTools`) + skills content into `systemPrompt`
- [ ] Call `buildSystemPrompt()` in mainline after skills and MCP tool loading;
      write prompt character count to log

### Relevant context

- ReAct format reference: the LLM output grammar to instruct is:
  - `THOUGHT: <reasoning>`
  - `ACTION: <tool_name>` + `ACTION_INPUT: <json_args>` (tool invocation)
  - `CLARIFY: <question>` (blocking clarification request)
  - `ANSWER: <final_response>` (terminal step)
- System prompt is a varchar — must stay within `MAX_RESPONSE` (32000) or an
  adjusted `MAX_SYSTEM_PROMPT` constant

---

## Sub-task 7: Session state management

**Status:** `[x] done`

### Intent

Define the in-process session store that enables multi-turn and clarification
round-trips. A session holds the accumulated conversation history, the current
ReAct step number, and whether it is paused waiting for clarification.

### Expected outcomes

- Data structure `sessionDs` defined with fields: `sessId varchar(36)`,
  `history varchar(65535)` (growing conversation), `stepNum int(10)`,
  `paused ind`, `pendingQuestion varchar(4096)`
- In-memory array `sessions(100)` and `sessionCount int(10)` declared
- `newSession()` returns a new session ID (UUID-style from `%timestamp` +
  random suffix) and initialises a slot
- `findSession(id varchar(36))` returns the array index or -1
- `saveSession(idx int(10))` and `loadSession(idx int(10))` update the in-memory
  array (no disk persistence needed)

### Todo list

- [ ] Define `sessionDs` data structure
- [ ] Declare `sessions(100)` array and `sessionCount int(10) inz(0)`
- [ ] Implement `newSession() varchar(36)`: generate ID, init slot, return ID
- [ ] Implement `findSession(id varchar(36)) int(10)`: linear scan, return index
      or -1
- [ ] Define `MAX_SESSIONS` constant (100); log a warning and reject new queries
      when the limit is hit

### Relevant context

- Session IDs: `%char(%timestamp() : *ISO0)` + four-digit counter suffix is
  sufficient
- No persistence needed: sessions are lost when the agent job ends (by design)

---

## Sub-task 8: ReAct loop

**Status:** `[x] done`

### Intent

Implement the core `runReact(sessIdx int(10) : userInput varchar(MAX_PROMPT))`
procedure. It appends user input to session history, calls the LLM, parses the
LLM output for the ReAct grammar tags, and either invokes a tool (looping),
records a clarification pause, or records a final answer.

### Expected outcomes

- `runReact` appends `User: <input>` to session history, then loops:
  1. Calls `callLLM` with `systemPrompt + '\n\n' + session.history`
  2. Parses LLM response for `THOUGHT:`, `ACTION:`, `ACTION_INPUT:`,
     `CLARIFY:`, or `ANSWER:` prefix
  3. On `ACTION:` — calls `callMcpTool`, appends tool result to history,
     continues loop
  4. On `CLARIFY:` — sets `session.paused = *on`, stores question in
     `session.pendingQuestion`, returns immediately
  5. On `ANSWER:` — stores answer, marks session complete, returns
- Maximum step guard (`MAX_REACT_STEPS = 10`) prevents infinite loops; if
  exceeded, returns an error answer
- All LLM calls and tool calls are written to the log

### Todo list

- [ ] Implement `parseReactTag(response varchar(MAX_RESPONSE) : tag varchar(20))
      varchar(MAX_RESPONSE)`: extracts text after the given tag prefix on its line
- [ ] Implement `runReact(sessIdx int(10) : userInput varchar(MAX_PROMPT))`:
      the loop described above
- [ ] Declare `MAX_REACT_STEPS` constant (10)
- [ ] Log each step: step number, tag detected, tool invoked (if any)

### Relevant context

- History format: plain text accumulation of
  `User: <msg>\nAssistant: <response>\n` turns
- `callLLM` prompt argument is now the full history string (needs `MAX_PROMPT`
  to be large enough — set to 16000)
- `callMcpTool` from sub-task 5 is called here with `mcpUrl` global

---

## Sub-task 9: HTTP server and request dispatcher

**Status:** `[x] done`

### Intent

Implement the HTTP server loop using HTTPAPI's server-side APIs (or, if HTTPAPI
does not expose a server accept loop, use IBM i socket APIs `QsoCreateIOSocket`
/ `bind` / `listen` / `accept` with manual HTTP framing). Parse incoming POST
request bodies as JSON, route to the correct handler, and write JSON responses.

> **Note for implementer:** HTTPAPI is primarily a client library. If it does
> not provide a suitable server accept loop, fall back to IBM i BSD socket APIs
> (`socket`, `bind`, `listen`, `accept`, `recv`, `send`) prototyped from RPG
> via `extproc`. The socket approach is well-documented for ILE RPG. Choose the
> simpler path that actually works for server-side HTTP on IBM i.

### Expected outcomes

- Program parses `listenAddr` argument into interface string and port integer
- Opens a TCP listen socket on the given interface and port
- Loops: accepts a connection, reads the HTTP request line + headers + body,
  dispatches based on method and path:
  - `POST /query` — new query or clarification continuation
  - `GET /health` — returns `{"status":"ok"}` (optional but useful)
- Writes a well-formed HTTP/1.0 response with `Content-Type: application/json`
- Log: connection source, method, path, response status for every request

### Request JSON schema (`POST /query`)

```json
{
  "session_id": "<optional — omit for new session>",
  "query": "<user query or clarification answer>"
}
```

### Response JSON schemas

Final answer:

```json
{ "session_id": "...", "status": "answer", "response": "..." }
```

Clarification request:

```json
{ "session_id": "...", "status": "clarify", "question": "..." }
```

Error:

```json
{ "session_id": "...", "status": "error", "message": "..." }
```

### Todo list

- [ ] Parse `listenAddr` (format `<iface>:<port>`) into separate host and port
      variables
- [ ] Prototype socket APIs: `socket`, `bind`, `listen`, `accept`, `recv`,
      `send`, `close` via `extproc` (QSYSINC/H header equivalents)
- [ ] Implement `readHttpRequest(fd int(10))`: reads raw bytes, splits on
      `\r\n\r\n`, returns body string and extracts `Content-Length`
- [ ] Implement `writeHttpResponse(fd int(10) : statusCode int(10) :
      body varchar(MAX_RESPONSE))`: writes HTTP/1.0 status line, headers, body
- [ ] Implement `handleQuery(body varchar(MAX_RESPONSE)) varchar(MAX_RESPONSE)`:
      parses JSON body, looks up or creates session, calls `runReact` or resumes
      paused session, returns JSON response string
- [ ] Main server loop: `socket` → `bind` → `listen` → loop `accept` →
      `readHttpRequest` → dispatch → `writeHttpResponse` → close connection fd
- [ ] Log startup message including interface and port when server is ready

### Relevant context

- Socket API prototypes: IBM i ILE C headers in QSYSINC (e.g. `sys/socket.h`,
  `netinet/in.h`, `arpa/inet.h`) — use `extproc` name matching the ILE C symbols
- JSON body parse: `DATA-INTO` / YAJLINTO for request; manual string build or
  `DATA-GEN` / YAJLDTAGEN for response
- `listenAddr` parse: `%scan(':' : listenAddr)` to find split point

---

## Sub-task 10: Makefile integration, README files, and build validation

**Status:** `[x] done`

### Intent

Wire everything together: ensure the sub-makefile compiles the finished program,
the top-level `Makefile` builds it, `src/LLMRPGAGT/README.md` provides full
standalone documentation of the agent (including all external dependencies), and
the top-level `README.md` is updated to reference it.

### Expected outcomes

- `make agt` from the project root compiles `LLMRPGAGT` successfully into
  `TARGET_LIB`
- `src/LLMRPGAGT/README.md` exists and fully documents the agent as a
  standalone reference (see content requirements below)
- Top-level `README.md` has a new `## LLMRPGAGT` section that summarises the
  agent and links to `src/LLMRPGAGT/README.md`
- `src/LLMRPGAGT/` is listed in the project layout table in the top-level
  `README.md`

### `src/LLMRPGAGT/README.md` required content

The file must cover all of the following in order:

1. **Purpose** — what the agent does; ReAct pattern description
2. **Arguments** — table of all five positional parameters with types,
   required/optional, and defaults
3. **HTTP API** — endpoint table; full request and response JSON schemas for
   `POST /query` (new query, clarification continuation) and `GET /health`;
   clarification round-trip sequence diagram in plain text or Mermaid
4. **ReAct grammar** — the `THOUGHT` / `ACTION` / `ACTION_INPUT` / `CLARIFY` /
   `ANSWER` tag format the agent instructs the LLM to use
5. **Skills file format** — that it is a Markdown file injected verbatim as
   system-prompt context; what to put in it
6. **MCP integration** — how the agent connects at startup (`tools/list`),
   how tools are presented to the LLM, how `tools/call` is invoked during the
   ReAct loop; MCP server URL format
7. **Session management** — how session IDs work; how to resume a paused
   (clarification) session; in-process session limit (100); sessions are not
   persisted across agent restarts
8. **Log file** — format of log entries; default path pattern; how to specify a
   custom path
9. **External dependencies** — a dedicated section listing every external
   library and system prerequisite the agent requires, with version/install
   guidance where known:
   - `DBSDK_V1` library (IBM AI-SDK-Db2-IBMi) — must be on the library list;
     supplies all LLM SQL scalar functions
   - `HTTPAPI` (`LIBHTTP` binding directory) — used for outbound HTTP POST
     to MCP server; must be installed and on the library list
   - `YAJL` binding directory — JSON parse (`YAJLINTO`) and generate
     (`YAJLDTAGEN`) parsers; must be installed and on the library list
   - IBM i socket APIs (`sys/socket.h`, `netinet/in.h`, `arpa/inet.h`) —
     available in QSYSINC; no separate install required
   - PASE C runtime (`open`/`write`/`close`/`fopen`/`fread`/`fclose`) —
     part of IBM i PASE; no separate install required
   - `DBSDK_DEMO` (or caller-supplied `TARGET_LIB`) — library where the
     compiled program object lives
10. **Building** — `make agt` invocation; Makefile variable overrides
11. **Running** — `CALL PGM(...)` with example argument values

### Todo list

- [ ] Verify `src/LLMRPGAGT/Makefile` (from sub-task 1) correctly references
      the finished source file name
- [ ] Run `make agt` and fix any compilation errors
- [ ] Create `src/LLMRPGAGT/README.md` covering all 11 sections listed above
- [ ] Run `npx prettier --write --prose-wrap always src/LLMRPGAGT/README.md`
- [ ] Add `## LLMRPGAGT` summary section to top-level `README.md` with a link
      to `src/LLMRPGAGT/README.md`
- [ ] Add `src/LLMRPGAGT/` row to the project layout table in top-level
      `README.md`
- [ ] Run `npx prettier --write --prose-wrap always README.md`

### Relevant context

- Top-level `Makefile` pattern: [`Makefile`](Makefile)
- Top-level README structure to follow: [`README.md`](README.md)
- Markdown authoring rules: [`.bob/rules/markdown-rules.md`](.bob/rules/markdown-rules.md)

