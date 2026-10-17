# LLMRPGAGT

**Date:** 2025-07-31

**License:** Apache License, Version 2.0 —
<https://www.apache.org/licenses/LICENSE-2.0>

**Authors:** Jack Woehr \<<jwoehr@softwoehr.com>\>, IBM Bob (AI pair programmer)

---

## Purpose

`LLMRPGAGT` is a ReAct (Reason-Act) agent implemented in ILE SQL RPG for IBM i.
It runs as a persistent, headless server job that exposes a JSON HTTP API on a
configurable interface and port.

When a query arrives, the agent drives a multi-step loop against an LLM backend
configured through `DBSDK_V1`:

1. **Reason** — the LLM generates a `THOUGHT` explaining its next step.
2. **Act** — the LLM either calls an MCP tool (`ACTION` + `ACTION_INPUT`),
   requests a clarification from the caller (`CLARIFY`), or produces a final
   response (`ANSWER`).
3. The agent invokes the requested tool, appends the result to the conversation
   history, and loops back to step 1 — until it either answers or asks for
   clarification.

Clarification is a blocking round-trip: the agent returns a `clarify` status
with a question, and the caller re-POSTs with the same `session_id` and the
clarification answer to resume the loop.

---

## Arguments

The program takes five positional parameters:

| #   | Name           | Type            | Required | Default                              | Description                                                |
| --- | -------------- | --------------- | -------- | ------------------------------------ | ---------------------------------------------------------- |
| 1   | `providerName` | `varchar(20)`   | Yes      | —                                    | LLM backend: `'ollama'` or `'openai_compatible'`           |
| 2   | `listenAddr`   | `varchar(100)`  | Yes      | —                                    | Interface and port to serve on, e.g. `'0.0.0.0:8080'`      |
| 3   | `mcpUrl`       | `varchar(1000)` | No       | _(omitted)_                          | MCP server URL including port, e.g. `'http://myhost:3000'` |
| 4   | `skillsPath`   | `varchar(1000)` | No       | _(omitted)_                          | IFS path to a Markdown skills file                         |
| 5   | `logPath`      | `varchar(1000)` | No       | `/tmp/llmrpgagt<YYYYMMDDHHMMSS>.log` | IFS path for the log file                                  |

---

## HTTP API

### Endpoints

| Method | Path      | Description                                 |
| ------ | --------- | ------------------------------------------- |
| `POST` | `/query`  | Submit a user query or clarification answer |
| `GET`  | `/health` | Liveness check — returns `{"status":"ok"}`  |

### `POST /query` — request body

```json
{
  "session_id": "<optional — omit to start a new session>",
  "query": "<user query text or clarification answer>"
}
```

- Omit `session_id` (or leave it blank) to start a new conversation.
- Include the `session_id` returned from a previous `clarify` response to resume
  a paused session.

### `POST /query` — response bodies

**Final answer:**

```json
{ "session_id": "...", "status": "answer", "response": "..." }
```

**Clarification request:**

```json
{ "session_id": "...", "status": "clarify", "question": "..." }
```

**Error:**

```json
{ "session_id": "...", "status": "error", "message": "..." }
```

### Clarification round-trip

The following diagram shows the sequence for a query that requires clarification
before the agent can answer.

```text
Caller                        LLMRPGAGT
  |                               |
  |-- POST /query (no session) -->|
  |                               |-- callLLM() --> LLM
  |                               |<-- CLARIFY: "Which database?" --
  |<-- {"status":"clarify",       |
  |     "session_id":"S1",        |
  |     "question":"Which DB?"} --|
  |                               |
  |-- POST /query                 |
  |   {"session_id":"S1",         |
  |    "query":"Db2 for i"} ----->|
  |                               |-- callLLM() --> LLM
  |                               |<-- ANSWER: "Here is..." --
  |<-- {"status":"answer",        |
  |     "session_id":"S1",        |
  |     "response":"Here is..."} -|
```

---

## ReAct grammar

The agent instructs the LLM to output responses in the following tagged format.

```text
THOUGHT: <reasoning about the next step>
ACTION: <tool_name>
ACTION_INPUT: <json object with tool arguments>
```

Or to request clarification:

```text
THOUGHT: <reasoning>
CLARIFY: <question for the caller>
```

Or to provide a final answer:

```text
THOUGHT: <reasoning>
ANSWER: <final response text>
```

The agent parses each LLM response for these tags in the order: `ANSWER` →
`CLARIFY` → `ACTION`. A maximum of 10 ReAct steps is enforced per session turn;
if exceeded, the agent returns an error answer.

---

## Skills file format

When a `skillsPath` argument is provided, the agent reads the entire Markdown
file at that IFS path and injects its content verbatim into the LLM system
prompt at startup.

The skills file is not parsed — it is included as a plain context block after
the ReAct instruction section. Use it to describe domain knowledge, response
style guidelines, or any other static context the LLM should always have
available.

Example skills file content:

```markdown
## Domain knowledge

This agent assists with IBM i system administration. Prefer CL command names
over IFS paths in responses. All SQL should target Db2 for i syntax.
```

The skills content is loaded once at startup. Changes to the file after the
agent starts are not picked up without a restart.

---

## MCP integration

If an `mcpUrl` argument is provided, the agent performs the following steps at
startup:

1. **Tool discovery** — sends a JSON-RPC 2.0 `tools/list` request to `<mcpUrl>`:

   ```json
   { "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {} }
   ```

   The returned tool names and descriptions are appended to the LLM system
   prompt so the LLM knows which tools are available.

2. **Tool invocation** — during the ReAct loop, when the LLM outputs an
   `ACTION:` tag, the agent sends a `tools/call` request to `<mcpUrl>`:

   ```json
   {
     "jsonrpc": "2.0",
     "id": 2,
     "method": "tools/call",
     "params": {
       "name": "<tool_name>",
       "arguments": <json_args>
     }
   }
   ```

   The tool result is appended to the conversation history and the ReAct loop
   continues.

The MCP URL must include protocol and port, for example `http://myhost:3000`. Up
to 50 tools are supported. If the MCP server is unreachable at startup, the
agent logs a warning and continues without tool support.

---

## Session management

- Each call to `POST /query` without a `session_id` allocates a new session.
- The response always includes the `session_id`; the caller must echo it back to
  continue the same conversation.
- Sessions are stored in memory within the agent job. The maximum number of
  concurrent sessions is **100**. When the limit is reached, new queries return
  an error until existing sessions are exhausted.
- Sessions are **not persisted** — they are lost when the agent job ends.
- A session ID has the form `YYYYMMDDHHMMSS-<counter>`, for example
  `20250731143012-1`.

---

## Log file

Every significant event is written to the log file: startup parameters, LLM
provider config, MCP tool discovery, ReAct steps, tool calls, HTTP requests, and
errors.

**Entry format:**

```text
[2025-07-31-14.30.12.000000] <message>
```

**Default path:**

```text
/tmp/llmrpgagt<YYYYMMDDHHMMSS>.log
```

For example: `/tmp/llmrpgagt20250731143012.log`

**Custom path:** supply argument 5 to the program. The file is created if it
does not exist and is appended to if it does.

---

## External dependencies

All of the following must be installed and available before building or running
`LLMRPGAGT`.

| Dependency                                                                   | Where needed                                                                                                                 | Install / verify                                                                                              |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------- |
| **`DBSDK_V1`** library (IBM AI-SDK-Db2-IBMi)                                 | Runtime — all LLM SQL scalar functions (`ollama_generate`, `openai_compatible_chat_generate`, config `get`/`set` procedures) | Install from <https://github.com/IBM/AI-SDK-Db2-IBMi>; add to library list with `ADDLIBLE DBSDK_V1`           |
| **`HTTPAPI`** — binding directory `LIBHTTP`                                  | Runtime — outbound HTTP POST to the MCP server (`tools/list`, `tools/call`)                                                  | Install HTTPAPI from <https://github.com/ScottKlement/httpapi>; library `LIBHTTP` must be on the library list |
| **`YAJL`** — binding directory `YAJL`                                        | Runtime — JSON parsing (`YAJLINTO`) and generation (`YAJLDTAGEN`)                                                            | Install YAJL from <https://github.com/ScottKlement/yajl>; library `YAJL` must be on the library list          |
| **IBM i socket APIs** (`socket`, `bind`, `listen`, `accept`, `recv`, `send`) | Runtime — TCP HTTP server loop                                                                                               | Available in QSYSINC (`sys/socket.h`, `netinet/in.h`, `arpa/inet.h`); no separate install required            |
| **PASE C runtime** (`open`, `write`, `close`, `fopen`, `fread`, `fclose`)    | Runtime — IFS log file and skills file I/O                                                                                   | Part of IBM i PASE; no separate install required                                                              |
| **`DBSDK_DEMO`** library (or caller-supplied `TARGET_LIB`)                   | Build and runtime — library where the compiled `LLMRPGAGT` program object lives                                              | Create with `CRTLIB LIB(DBSDK_DEMO)` if it does not exist                                                     |
| **IBM i PASE** (`cl`, `system` commands in PATH)                             | Build only — required by the Makefile                                                                                        | Included with IBM i PASE; ensure PASE is active                                                               |
| **GNU make**                                                                 | Build only                                                                                                                   | Available in IBM i PASE via `yum install make`                                                                |

---

## Source files

| File                                       | Description                                        |
| ------------------------------------------ | -------------------------------------------------- |
| [`LLMRPGAGT.SQLRPGLE`](LLMRPGAGT.SQLRPGLE) | ILE SQL RPG agent program                          |
| [`LLMRPGAGC.CLLE`](LLMRPGAGC.CLLE)         | CL command processing program (CPP) for the `*CMD` |
| [`LLMRPGAGT.CMD`](LLMRPGAGT.CMD)           | IBM i `*CMD` object definition                     |

---

## Building

Run from the [`src/LLMRPGAGT/`](./) directory, or use the top-level `Makefile`
with the `agt` target.

```text
# From the project root
make agt [TARGET_LIB=<lib>] [VERBOSE=1]

# From src/LLMRPGAGT/
make [TARGET_LIB=<lib>] [VERBOSE=1]
```

The default `all` target builds the RPG program, the CPP (`LLMRPGAGC`), and the
`*CMD` (`LLMRPGAGT`). Individual targets are also available:

| Target  | Description                                   |
| ------- | --------------------------------------------- |
| `all`   | Build everything (default)                    |
| `rpgle` | Build the SQL RPG program only                |
| `cpp`   | Build the CL command processing program only  |
| `cmd`   | Build the `*CMD` (also builds the CPP)        |
| `clean` | Delete all compiled objects from `TARGET_LIB` |

| Variable     | Default      | Description                                      |
| ------------ | ------------ | ------------------------------------------------ |
| `TARGET_LIB` | `DBSDK_DEMO` | IBM i library to compile the program object into |
| `VERBOSE`    | `0`          | Set to `1` to show full `cl`/`system` output     |

**Prerequisites before building:**

- `TARGET_LIB` must exist.
- `DBSDK_V1`, `LIBHTTP`, and `YAJL` must be on the library list.
- IBM i PASE must be active.

---

## Running

After a successful build, add the library to the library list and invoke the
agent.

### Using the `*CMD`

Press `F4` on the command line after typing `LLMRPGAGT` to get the prompted
parameter screen:

```text
ADDLIBLE LIB(DBSDK_DEMO)
ADDLIBLE LIB(DBSDK_V1)
ADDLIBLE LIB(LIBHTTP)
ADDLIBLE LIB(YAJL)

LLMRPGAGT PROVIDER('openai_compatible') LISTEN('0.0.0.0:8080')
```

With all optional parameters:

```text
LLMRPGAGT PROVIDER('openai_compatible') +
          LISTEN('0.0.0.0:8080') +
          MCPURL('http://myhost:3000') +
          SKILLS('/home/jwoehr/skills.md') +
          LOGPATH('/tmp/myagent.log')
```

### Using `CALL PGM` directly

```text
ADDLIBLE LIB(DBSDK_DEMO)
ADDLIBLE LIB(DBSDK_V1)
ADDLIBLE LIB(LIBHTTP)
ADDLIBLE LIB(YAJL)

CALL PGM(DBSDK_DEMO/LLMRPGAGT) PARM('openai_compatible' '0.0.0.0:8080')
```

With all optional arguments:

```text
CALL PGM(DBSDK_DEMO/LLMRPGAGT) PARM(
    'openai_compatible'
    '0.0.0.0:8080'
    'http://myhost:3000'
    '/home/jwoehr/skills.md'
    '/tmp/myagent.log'
)
```

The program runs as a persistent job. Use `ENDJOB` or `SIGNOFF` to stop it.

### Example: submit as a batch job using the `*CMD`

```text
SBMJOB CMD(LLMRPGAGT PROVIDER('ollama') LISTEN('0.0.0.0:9090')) +
       JOB(LLMRPGAGT) JOBD(*LIBL/QBATCH) +
       INLLIBL(*JOBD DBSDK_DEMO DBSDK_V1 LIBHTTP YAJL)
```

### Example: submit as a batch job using `CALL PGM`

```text
SBMJOB CMD(CALL PGM(DBSDK_DEMO/LLMRPGAGT) PARM('ollama' '0.0.0.0:9090'))
       JOB(LLMRPGAGT) JOBD(*LIBL/QBATCH) INLLIBL(*JOBD DBSDK_DEMO DBSDK_V1 LIBHTTP YAJL)
```
