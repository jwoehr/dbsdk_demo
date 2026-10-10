**free
// =============================================================================
// File:    LLMRPGAGT.SQLRPGLE
// Date:    2025-07-31
// Purpose: IBM i ILE RPG ReAct (Reason-Act) agent that:
//            - Loads LLM provider config from DBSDK_V1
//            - Optionally connects to an MCP server for tool discovery
//            - Optionally loads a Markdown skills file as system context
//            - Builds a ReAct system prompt and serves it over HTTP
//            - Accepts POST /query requests, drives a multi-step ReAct loop,
//              and returns JSON responses (answer / clarify / error)
//            - Supports blocking clarification round-trips via session IDs
// License: Apache License, Version 2.0
//          https://www.apache.org/licenses/LICENSE-2.0
// Authors: Jack Woehr <jwoehr@softwoehr.com>
//          IBM Bob (AI pair programmer)
// =============================================================================

ctl-opt dftactgrp(*no) actgrp(*new)
        option(*srcstmt : *nodebugio : *nounref);

// Five program parameters
dcl-pi *n;
    providerName  varchar(20)   const;                          // required
    listenAddr    varchar(100)  const;                          // required: iface:port
    mcpUrl        varchar(1000) const options(*nopass); // optional
    skillsPath    varchar(1000) const options(*nopass); // optional
    logPath       varchar(1000) const options(*nopass); // optional
end-pi;

// ---------------------------------------------------------------------------
// HTTPAPI / YAJL includes
// ---------------------------------------------------------------------------
/include LIBHTTP/QRPGLESRC,HTTPAPI_H
/include YAJL/QRPGLESRC,YAJL_H

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
dcl-c  MAX_RESPONSE    32000;
dcl-c  MAX_PROMPT      16000;
dcl-c  MAX_SYSTEM      65535;
dcl-c  MAX_SKILLS      65535;
dcl-c  MAX_LOG_MSG     4096;
dcl-c  MAX_SESSIONS    100;
dcl-c  MAX_MCP_TOOLS   50;
dcl-c  MAX_REACT_STEPS 10;
dcl-c  NL              x'25';    // EBCDIC newline / IFS LF
dcl-c  CRLF            x'0D25';  // HTTP line ending (EBCDIC CR+LF)
// JSON escape sequences (EBCDIC):  backslash=x'E0', quote=x'7F'
dcl-c  JS_BKSLASH      x'E0';            // single backslash char
dcl-c  JS_ESC_QUOTE    x'E07F';          // \"
dcl-c  JS_ESC_BKSLASH  x'E0E0';          // \\
dcl-c  JS_ESC_NL       x'E095';          // \n  (EBCDIC n = x'95')
dcl-c  JS_ESC_CR       x'E099';          // \r  (EBCDIC r = x'99')
dcl-c  JS_ESC_TAB      x'E005';          // \t  (EBCDIC HT = x'05')

// ---------------------------------------------------------------------------
// PASE C prototypes — IFS log file (3-arg open with mode)
// ---------------------------------------------------------------------------
dcl-pr c_open3  int(10) extproc('open64');
    path        pointer value options(*string);
    flags       int(10) value;
    mode        uns(10) value;
end-pr;

dcl-pr c_write  int(10) extproc('write');
    fd          int(10) value;
    buf         pointer value;
    nbytes      uns(10) value;
end-pr;

// open() flag constants (PASE O_* values for IFS)
dcl-c  O_WRONLY   2;
dcl-c  O_CREAT    8;
dcl-c  O_APPEND   8388608;
dcl-c  S_IRUSR    256;
dcl-c  S_IWUSR    128;
dcl-c  S_IRGRP    32;
dcl-c  S_IROTH    4;

// ---------------------------------------------------------------------------
// PASE C prototypes — IFS stream file read (skills file)
// ---------------------------------------------------------------------------
dcl-pr c_fopen  pointer extproc('fopen64');
    path        pointer value options(*string);
    mode        pointer value options(*string);
end-pr;

dcl-pr c_fread  uns(10) extproc('fread');
    buf         pointer value;
    size        uns(10) value;
    count       uns(10) value;
    stream      pointer value;
end-pr;

dcl-pr c_fclose int(10) extproc('fclose');
    stream      pointer value;
end-pr;

// ---------------------------------------------------------------------------
// Socket API prototypes
// ---------------------------------------------------------------------------
dcl-pr sock_socket  int(10) extproc('socket');
    domain      int(10) value;
    type        int(10) value;
    protocol    int(10) value;
end-pr;

dcl-pr sock_bind    int(10) extproc('bind');
    sockfd      int(10) value;
    addr        pointer value;
    addrlen     uns(10) value;
end-pr;

dcl-pr sock_listen  int(10) extproc('listen');
    sockfd      int(10) value;
    backlog     int(10) value;
end-pr;

// accept() — pass *null for addr/addrlen when peer address is not needed
dcl-pr sock_accept  int(10) extproc('accept');
    sockfd      int(10) value;
    addr        pointer value;
    addrlen     pointer value;
end-pr;

dcl-pr sock_recv    int(10) extproc('recv');
    sockfd      int(10) value;
    buf         pointer value;
    len         uns(10) value;
    flags       int(10) value;
end-pr;

dcl-pr sock_send    int(10) extproc('send');
    sockfd      int(10) value;
    buf         pointer value;
    len         uns(10) value;
    flags       int(10) value;
end-pr;

dcl-pr sock_close   int(10) extproc('close');
    fd          int(10) value;
end-pr;

dcl-pr sock_inet_addr uns(10) extproc('inet_addr');
    cp          pointer value options(*string);
end-pr;

dcl-pr sock_htons   uns(5) extproc('htons');
    hostshort   uns(5) value;
end-pr;

dcl-pr sock_setsockopt int(10) extproc('setsockopt');
    sockfd      int(10) value;
    level       int(10) value;
    optname     int(10) value;
    optval      pointer value;
    optlen      uns(10) value;
end-pr;

// Socket constants
dcl-c  AF_INET      2;
dcl-c  SOCK_STREAM  1;
dcl-c  SOL_SOCKET   1;
dcl-c  SO_REUSEADDR 4;
dcl-c  INADDR_ANY   0;

// ---------------------------------------------------------------------------
// QMHSNDPM prototype (error reporting to job log)
// ---------------------------------------------------------------------------
dcl-pr SendMessage extpgm('QMHSNDPM');
    msgId        char(7)   const;
    msgFile      char(20)  const;
    msgData      char(512) const;
    msgLength    int(10)   const;
    msgType      char(10)  const;
    stackEntry   char(10)  const;
    stackCounter int(10)   const;
    msgKey       char(4);
    errorDs      char(16);
end-pr;

// ---------------------------------------------------------------------------
// Global LLM config (mirrors LLMRPG pattern)
// ---------------------------------------------------------------------------
dcl-s backend   varchar(20)   inz('ollama');
dcl-s protocol  varchar(10);
dcl-s g_server  varchar(1000);
dcl-s g_port    int(10);
dcl-s model     varchar(1000);
dcl-s apikey    varchar(8000);
dcl-s basepath  varchar(1000);

// ---------------------------------------------------------------------------
// Global state
// ---------------------------------------------------------------------------
dcl-s logFd         int(10)  inz(-1);
dcl-s skillsContent varchar(MAX_SKILLS);
dcl-s systemPrompt  varchar(MAX_SYSTEM);
dcl-s g_mcpUrl      varchar(1000);
dcl-s sessionCounter int(10) inz(0);

// ---------------------------------------------------------------------------
// MCP tool descriptor template
// ---------------------------------------------------------------------------
dcl-ds mcpToolDs qualified template;
    toolName   varchar(200);
    toolDesc   varchar(1000);
    toolSchema varchar(2000);
end-ds;

dcl-ds mcpTools   likeds(mcpToolDs) dim(MAX_MCP_TOOLS);
dcl-s  mcpToolCount int(10) inz(0);

// ---------------------------------------------------------------------------
// Session data structure template
// ---------------------------------------------------------------------------
dcl-ds sessionDs qualified template;
    sessId          varchar(36);
    history         varchar(65535);
    stepNum         int(10);
    paused          ind;
    pendingQuestion varchar(4096);
    finalAnswer     varchar(MAX_RESPONSE);
    done            ind;
end-ds;

dcl-ds sessions   likeds(sessionDs) dim(MAX_SESSIONS);
dcl-s  sessionCount int(10) inz(0);

// ---------------------------------------------------------------------------
// Flat DS for parsing MCP tools/list JSON response via YAJLINTO.
// YAJLINTO maps each JSON key to a subfield by name.  The array element count
// is returned in the num_-prefixed sibling field.
// JSON shape expected:
//   {"result":{"tools":[{"name":"...","description":"..."}]}}
// YAJLINTO flattens nested objects, so we just name subfields after the
// leaf keys and rely on allowextra=yes to ignore anything else.
// ---------------------------------------------------------------------------
dcl-ds mcpListParse qualified;
    num_tools    int(10)       inz(0);
    t_name       varchar(200)  dim(MAX_MCP_TOOLS);
    t_desc       varchar(1000) dim(MAX_MCP_TOOLS);
end-ds;

// Flat DS for parsing MCP tools/call JSON response.
// JSON shape: {"result":{"content":[{"type":"text","text":"..."}]}}
dcl-ds mcpCallParse qualified;
    num_content  int(10)           inz(0);
    c_type       varchar(50)       dim(10);
    c_text       varchar(MAX_RESPONSE) dim(10);
end-ds;

// Flat DS for parsing POST /query request body.
// JSON shape: {"session_id":"...","query":"..."}
dcl-ds queryReqDs qualified;
    q_session_id  varchar(36);
    q_query       varchar(MAX_PROMPT);
end-ds;

// ---------------------------------------------------------------------------
// SQL options
// ---------------------------------------------------------------------------
Exec SQL SET OPTION
    COMMIT=*NONE,
    DATFMT=*ISO,
    NAMING=*SYS;

// ===========================================================================
// Mainline
// ===========================================================================

// 1. Open log
if %parms() >= 5 and %trim(logPath) <> '';
    openLog(%trim(logPath));
else;
    openLog('');
endif;

writeLog('LLMRPGAGT starting.');
writeLog('Provider: ' + providerName);
writeLog('Listen:   ' + listenAddr);

// 2. Bootstrap LLM provider config
backend = providerName;
fetchConfig();
setForJob();
writeLog('LLM provider configured: ' + backend);

// 3. Connect to MCP server (optional)
if %parms() >= 3 and %trim(mcpUrl) <> '';
    g_mcpUrl = %trim(mcpUrl);
    writeLog('Connecting to MCP server: ' + g_mcpUrl);
    fetchMcpTools(g_mcpUrl);
    writeLog('MCP tools loaded: ' + %char(mcpToolCount));
else;
    writeLog('No MCP server specified - tool calls disabled.');
endif;

// 4. Load skills file (optional)
if %parms() >= 4 and %trim(skillsPath) <> '';
    writeLog('Loading skills file: ' + %trim(skillsPath));
    loadSkills(%trim(skillsPath));
else;
    writeLog('No skills file specified.');
endif;

// 5. Build system prompt
buildSystemPrompt();
writeLog('System prompt built (' + %char(%len(systemPrompt)) + ' chars).');

// 6. Start HTTP server
writeLog('Starting HTTP server on ' + listenAddr + ' ...');
serveHttp();

writeLog('HTTP server exited.');
*inlr = *on;
return;

// ===========================================================================
// writeToFd — writes a varchar string to an open IFS file descriptor.
// Uses a fixed char buffer to avoid %addr-of-varchar issues.
// ===========================================================================
dcl-proc writeToFd;
    dcl-pi *n;
        fd   int(10)           const;
        data varchar(MAX_SYSTEM) const;
    end-pi;

    dcl-s buf  char(MAX_SYSTEM);
    dcl-s len  int(10);
    dcl-s rc   int(10);

    len = %len(data);
    if len = 0;
        return;
    endif;
    buf = data;
    rc  = c_write(fd : %addr(buf) : %uns(len));

end-proc writeToFd;

// ===========================================================================
// openLog — opens (or creates) the IFS log file.
// reqPath = '' uses the default timestamped path.
// ===========================================================================
dcl-proc openLog;
    dcl-pi *n;
        reqPath  varchar(1000) const;
    end-pi;

    dcl-s resolvedPath varchar(1000);
    dcl-s ts           varchar(20);
    dcl-s flags        int(10);
    dcl-s mode         uns(10);

    if reqPath <> '';
        resolvedPath = reqPath;
    else;
        ts = %subst(%char(%timestamp() : *ISO0) : 1 : 14);
        resolvedPath = '/tmp/llmrpgagt' + ts + '.log';
    endif;

    flags = O_WRONLY + O_CREAT + O_APPEND;
    mode  = S_IRUSR + S_IWUSR + S_IRGRP + S_IROTH;

    logFd = c_open3(%trim(resolvedPath) : flags : mode);

    if logFd < 0;
        SendProgramMessage('LLMRPGAGT: cannot open log ' + %trim(resolvedPath));
    endif;

end-proc openLog;

// ===========================================================================
// writeLog — writes a timestamped line to the IFS log file.
// ===========================================================================
dcl-proc writeLog;
    dcl-pi *n;
        msg  varchar(MAX_LOG_MSG) const;
    end-pi;

    dcl-s line  varchar(4128);
    dcl-s ts    varchar(27);

    if logFd < 0;
        return;
    endif;

    ts   = %char(%timestamp() : *ISO);
    line = '[' + ts + '] ' + msg + NL;
    writeToFd(logFd : line);

end-proc writeLog;

// ===========================================================================
// fetchConfig — reads DBSDK_V1 config into globals (ported from LLMRPG)
// ===========================================================================
dcl-proc fetchConfig;

    if backend = 'openai_compatible';

        Exec SQL SET :protocol = ( VALUES dbsdk_v1.openai_compatible_getprotocol() );
        Exec SQL SET :g_server = ( VALUES dbsdk_v1.openai_compatible_getserver() );
        Exec SQL SET :g_port   = ( VALUES dbsdk_v1.openai_compatible_getport() );
        Exec SQL SET :model    = ( VALUES dbsdk_v1.openai_compatible_getmodel() );
        Exec SQL SET :apikey   = ( VALUES dbsdk_v1.openai_compatible_getapikey() );
        Exec SQL SET :basepath = ( VALUES dbsdk_v1.openai_compatible_getbasepath() );

    else;
        Exec SQL SET :protocol = ( VALUES dbsdk_v1.ollama_getprotocol() );
        Exec SQL SET :g_server = ( VALUES dbsdk_v1.ollama_getserver() );
        Exec SQL SET :g_port   = ( VALUES dbsdk_v1.ollama_getport() );
        Exec SQL SET :model    = ( VALUES dbsdk_v1.ollama_getmodel() );
        apikey   = '';
        basepath = '';
    endif;

end-proc fetchConfig;

// ===========================================================================
// setForJob — pushes globals into SQL job-level settings (ported from LLMRPG)
// ===========================================================================
dcl-proc setForJob;

    dcl-s rc  int(10);

    if backend = 'openai_compatible';

        Exec SQL CALL dbsdk_v1.openai_compatible_setprotocolforjob( protocol  => TRIM(:protocol) );
        Exec SQL CALL dbsdk_v1.openai_compatible_setserverforjob(   hostname  => TRIM(:g_server) );
        Exec SQL CALL dbsdk_v1.openai_compatible_setportforjob(     port      => :g_port );
        Exec SQL CALL dbsdk_v1.openai_compatible_setmodelforjob(    model     => TRIM(:model) );
        Exec SQL CALL dbsdk_v1.openai_compatible_setapikeyforjob(   api_key   => TRIM(:apikey) );
        Exec SQL CALL dbsdk_v1.openai_compatible_setbasepathforjob( base_path => TRIM(:basepath) );

    else;
        Exec SQL CALL dbsdk_v1.ollama_setprotocolforjob( protocol => TRIM(:protocol) );
        Exec SQL CALL dbsdk_v1.ollama_setserverforjob(   hostname => TRIM(:g_server) );
        Exec SQL CALL dbsdk_v1.ollama_setportforjob(     port     => :g_port );
        Exec SQL CALL dbsdk_v1.ollama_setmodelforjob(    model    => TRIM(:model) );
    endif;

end-proc setForJob;

// ===========================================================================
// callLLM — submits a prompt to the configured LLM backend.
// Returns the LLM response text.
// ===========================================================================
dcl-proc callLLM;
    dcl-pi *n  varchar(MAX_RESPONSE);
        in_prompt  varchar(MAX_PROMPT) const;
    end-pi;

    dcl-s llmResponse  SQLTYPE(CLOB : 32000);
    dcl-s prompt       varchar(16100);
    dcl-s rtnVal       varchar(MAX_RESPONSE);

    if backend = 'openai_compatible';

        Exec SQL
            SET :llmResponse = (
                VALUES dbsdk_v1.openai_compatible_chat_generate(
                    prompt   => TRIM(:in_prompt),
                    options  => '{}' )
            );

    else;
        Exec SQL
            SET :prompt = (
                VALUES JSON_OBJECT(
                    KEY 'role'    VALUE 'user',
                    KEY 'content' VALUE TRIM(:in_prompt)
                )
            );

        Exec SQL
            SET :llmResponse = (
                VALUES dbsdk_v1.ollama_generate( prompt => :prompt )
            );

    endif;

    if sqlcode <> 0;
        writeLog('callLLM SQL error: ' + %char(sqlcode));
        return 'ANSWER: Error calling LLM (sqlcode=' + %char(sqlcode) + ')';
    endif;

    if llmResponse_LEN > 0;
        rtnVal = %subst(llmResponse_DATA : 1 : llmResponse_LEN);
    else;
        rtnVal = '';
    endif;

    return rtnVal;

end-proc callLLM;

// ===========================================================================
// loadSkills — reads the IFS Markdown skills file into skillsContent
// ===========================================================================
dcl-proc loadSkills;
    dcl-pi *n;
        path  varchar(1000) const;
    end-pi;

    dcl-s fp        pointer;
    dcl-s buf       char(4096);
    dcl-s bytesRead uns(10);
    dcl-s total     uns(10) inz(0);
    dcl-s rc        int(10);

    skillsContent = '';

    fp = c_fopen(%trim(path) : 'r');
    if fp = *null;
        writeLog('loadSkills: cannot open ' + %trim(path));
        return;
    endif;

    dou bytesRead = 0;
        bytesRead = c_fread(%addr(buf) : 1 : %size(buf) : fp);
        if bytesRead > 0;
            skillsContent += %subst(buf : 1 : bytesRead);
            total += bytesRead;
        endif;
    enddo;

    rc = c_fclose(fp);
    writeLog('loadSkills: read ' + %char(total) + ' bytes from ' + %trim(path));

end-proc loadSkills;

// ===========================================================================
// httpPost — makes an outbound HTTP POST using HTTPAPI, returns response body.
// body is passed as varchar; copied to a char buffer for %addr compatibility.
// ===========================================================================
dcl-proc httpPost;
    dcl-pi *n  varchar(MAX_RESPONSE);
        url   varchar(1000) const;
        body  varchar(5500) const;
    end-pi;

    dcl-s response varchar(MAX_RESPONSE);

    dcl-s rc2  int(10);

    monitor;
        rc2 = http_setOption('content-type' : 'application/json');
        response = HTTP_String('POST'
                             : %trim(url)
                             : body);
    on-error;
        response = '';
    endmon;

    return response;

end-proc httpPost;

// ===========================================================================
// fetchMcpTools — calls tools/list on the MCP server
// ===========================================================================
dcl-proc fetchMcpTools;
    dcl-pi *n;
        url  varchar(1000) const;
    end-pi;

    dcl-s reqBody  varchar(256);
    dcl-s response varchar(MAX_RESPONSE);
    dcl-s i        int(10);

    mcpToolCount = 0;

    reqBody = '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}';

    response = httpPost(%trim(url) : reqBody);

    if response = '';
        writeLog('fetchMcpTools: no response from MCP server.');
        return;
    endif;

    clear mcpListParse;

    monitor;
        Data-Into mcpListParse
            %Data(response : 'case=any allowextra=yes countprefix=num_')
            %Parser('YAJLINTO');
    on-error;
        writeLog('fetchMcpTools: JSON parse error.');
        return;
    endmon;

    for i = 1 to mcpListParse.num_tools;
        if i > MAX_MCP_TOOLS;
            leave;
        endif;
        mcpTools(i).toolName = mcpListParse.t_name(i);
        mcpTools(i).toolDesc = mcpListParse.t_desc(i);
        mcpToolCount += 1;
    endfor;

end-proc fetchMcpTools;

// ===========================================================================
// callMcpTool — invokes a tool on the MCP server via tools/call
// ===========================================================================
dcl-proc callMcpTool;
    dcl-pi *n  varchar(MAX_RESPONSE);
        url       varchar(1000) const;
        toolName  varchar(200)  const;
        toolArgs  varchar(4096) const;
    end-pi;

    dcl-s reqBody  varchar(5500);
    dcl-s response varchar(MAX_RESPONSE);
    dcl-s i        int(10);
    dcl-s rtnVal   varchar(MAX_RESPONSE);

    reqBody = '{"jsonrpc":"2.0","id":2,"method":"tools/call",' +
              '"params":{"name":"' + %trim(toolName) + '",' +
              '"arguments":' + %trim(toolArgs) + '}}';

    response = httpPost(%trim(url) : reqBody);

    if response = '';
        return 'Tool call returned empty response';
    endif;

    clear mcpCallParse;

    monitor;
        Data-Into mcpCallParse
            %Data(response : 'case=any allowextra=yes countprefix=num_')
            %Parser('YAJLINTO');
    on-error;
        writeLog('callMcpTool: JSON parse error for tool ' + %trim(toolName));
        return response;
    endmon;

    rtnVal = '';
    for i = 1 to mcpCallParse.num_content;
        if mcpCallParse.c_type(i) = 'text';
            if rtnVal <> '';
                rtnVal += NL;
            endif;
            rtnVal += mcpCallParse.c_text(i);
        endif;
    endfor;

    if rtnVal = '';
        rtnVal = response;
    endif;

    return rtnVal;

end-proc callMcpTool;

// ===========================================================================
// buildSystemPrompt — assembles the static ReAct system prompt
// ===========================================================================
dcl-proc buildSystemPrompt;

    dcl-s i  int(10);
    dcl-s p  varchar(MAX_SYSTEM);

    p = 'You are a helpful AI assistant operating in ReAct (Reason-Act) mode.' + NL +
        'For every user query, reason step by step and respond using only these tags:' + NL +
        NL +
        'THOUGHT: <your reasoning>' + NL +
        'ACTION: <tool_name>' + NL +
        'ACTION_INPUT: <json_args>' + NL +
        NL +
        'Or to request clarification:' + NL +
        'CLARIFY: <your question>' + NL +
        NL +
        'Or to give a final answer:' + NL +
        'ANSWER: <your final response>' + NL +
        NL +
        'Rules:' + NL +
        '- Always start with THOUGHT.' + NL +
        '- Use ACTION/ACTION_INPUT only when calling a tool.' + NL +
        '- Use CLARIFY only when you need more information.' + NL +
        '- Use ANSWER for the final response.' + NL +
        '- Do not output text outside the tagged lines.' + NL;

    if mcpToolCount > 0;
        p += NL + 'Available tools:' + NL;
        for i = 1 to mcpToolCount;
            p += '  - ' + %trim(mcpTools(i).toolName) +
                 ': '   + %trim(mcpTools(i).toolDesc) + NL;
        endfor;
    else;
        p += NL + 'No external tools are available.' + NL;
    endif;

    if skillsContent <> '';
        p += NL + '--- Skills / Context ---' + NL + skillsContent + NL;
    endif;

    systemPrompt = p;

end-proc buildSystemPrompt;

// ===========================================================================
// newSession — allocates a new session slot; returns the session ID.
// Returns '' if the session limit is reached.
// ===========================================================================
dcl-proc newSession;
    dcl-pi *n  varchar(36);
    end-pi;

    dcl-s id  varchar(36);
    dcl-s ts  varchar(14);

    if sessionCount >= MAX_SESSIONS;
        writeLog('newSession: session limit reached (' +
                 %char(MAX_SESSIONS) + ')');
        return '';
    endif;

    sessionCounter += 1;
    ts = %subst(%char(%timestamp() : *ISO0) : 1 : 14);
    id = ts + '-' + %editc(sessionCounter : 'X');

    sessionCount += 1;
    sessions(sessionCount).sessId          = id;
    sessions(sessionCount).history         = '';
    sessions(sessionCount).stepNum         = 0;
    sessions(sessionCount).paused          = *off;
    sessions(sessionCount).pendingQuestion = '';
    sessions(sessionCount).finalAnswer     = '';
    sessions(sessionCount).done            = *off;

    return id;

end-proc newSession;

// ===========================================================================
// findSession — returns 1-based index of session, or 0 if not found.
// ===========================================================================
dcl-proc findSession;
    dcl-pi *n  int(10);
        id  varchar(36) const;
    end-pi;

    dcl-s i  int(10);

    for i = 1 to sessionCount;
        if sessions(i).sessId = id;
            return i;
        endif;
    endfor;

    return 0;

end-proc findSession;

// ===========================================================================
// parseReactTag — extracts text after a tag prefix on its line.
// e.g. parseReactTag(llmOut : 'ANSWER') returns text after 'ANSWER: '.
// Returns '' if tag not found.
// ===========================================================================
dcl-proc parseReactTag;
    dcl-pi *n  varchar(MAX_RESPONSE);
        response  varchar(MAX_RESPONSE) const;
        tag       varchar(20)           const;
    end-pi;

    dcl-s needle   varchar(25);
    dcl-s pos      int(10);
    dcl-s afterTag varchar(MAX_RESPONSE);
    dcl-s nlPos    int(10);

    needle = %trim(tag) + ': ';
    pos = %scan(needle : response);
    if pos = 0;
        needle = %trim(tag) + ':';
        pos = %scan(needle : response);
    endif;
    if pos = 0;
        return '';
    endif;

    afterTag = %subst(response : pos + %len(needle));

    nlPos = %scan(NL : afterTag);
    if nlPos > 1;
        return %trim(%subst(afterTag : 1 : nlPos - 1));
    elseif nlPos = 0;
        return %trim(afterTag);
    endif;

    return '';

end-proc parseReactTag;

// ===========================================================================
// runReact — drives the ReAct loop for one session turn.
// Returns the response text.  After return check .paused and .done.
// ===========================================================================
dcl-proc runReact;
    dcl-pi *n  varchar(MAX_RESPONSE);
        sessIdx   int(10)             const;
        userInput varchar(MAX_PROMPT) const;
    end-pi;

    dcl-s fullPrompt  varchar(MAX_PROMPT);
    dcl-s llmOut      varchar(MAX_RESPONSE);
    dcl-s action      varchar(200);
    dcl-s actionInput varchar(4096);
    dcl-s clarify     varchar(4096);
    dcl-s answer      varchar(MAX_RESPONSE);
    dcl-s toolResult  varchar(MAX_RESPONSE);
    dcl-s step        int(10);

    sessions(sessIdx).history += 'User: ' + userInput + NL;
    sessions(sessIdx).paused   = *off;
    sessions(sessIdx).done     = *off;

    for step = 1 to MAX_REACT_STEPS;

        sessions(sessIdx).stepNum = step;

        fullPrompt = systemPrompt + NL + NL + sessions(sessIdx).history;
        if %len(fullPrompt) > MAX_PROMPT;
            fullPrompt = %subst(fullPrompt :
                                %len(fullPrompt) - MAX_PROMPT + 1);
        endif;

        writeLog('ReAct step ' + %char(step) +
                 ' session ' + sessions(sessIdx).sessId);

        llmOut = callLLM(fullPrompt);
        sessions(sessIdx).history += 'Assistant: ' + llmOut + NL;

        answer  = parseReactTag(llmOut : 'ANSWER');
        clarify = parseReactTag(llmOut : 'CLARIFY');
        action  = parseReactTag(llmOut : 'ACTION');

        if answer <> '';
            writeLog('ReAct step ' + %char(step) + ': ANSWER');
            sessions(sessIdx).finalAnswer = answer;
            sessions(sessIdx).done        = *on;
            return answer;

        elseif clarify <> '';
            writeLog('ReAct step ' + %char(step) + ': CLARIFY');
            sessions(sessIdx).paused          = *on;
            sessions(sessIdx).pendingQuestion = clarify;
            return clarify;

        elseif action <> '';
            actionInput = parseReactTag(llmOut : 'ACTION_INPUT');
            if actionInput = '';
                actionInput = '{}';
            endif;
            writeLog('ReAct step ' + %char(step) + ': ACTION=' +
                     %trim(action));

            if g_mcpUrl <> '';
                toolResult = callMcpTool(g_mcpUrl : action : actionInput);
            else;
                toolResult = 'No MCP server - tool call skipped.';
            endif;

            sessions(sessIdx).history +=
                'Tool(' + %trim(action) + '): ' + toolResult + NL;

        else;
            writeLog('ReAct step ' + %char(step) +
                     ': no tag - treating as ANSWER');
            sessions(sessIdx).finalAnswer = llmOut;
            sessions(sessIdx).done        = *on;
            return llmOut;
        endif;

    endfor;

    writeLog('ReAct: max steps reached for session ' +
             sessions(sessIdx).sessId);
    sessions(sessIdx).done        = *on;
    sessions(sessIdx).finalAnswer =
        'Maximum reasoning steps reached without a final answer.';
    return sessions(sessIdx).finalAnswer;

end-proc runReact;

// ===========================================================================
// sendOnFd — sends fixed-length char data on a socket fd.
// Copies varchar to char first to avoid %addr-of-varchar issues.
// ===========================================================================
dcl-proc sendOnFd;
    dcl-pi *n;
        fd    int(10)           const;
        data  varchar(MAX_SYSTEM) const;
    end-pi;

    dcl-s buf  char(MAX_SYSTEM);
    dcl-s len  uns(10);
    dcl-s rc   int(10);

    len = %uns(%len(data));
    if len = 0;
        return;
    endif;
    buf = data;
    rc  = sock_send(fd : %addr(buf) : len : 0);

end-proc sendOnFd;

// ===========================================================================
// readHttpRequest — reads one HTTP request from a connected socket fd.
// Returns the body; sets reqMethod and reqPath as output parameters.
// ===========================================================================
dcl-proc readHttpRequest;
    dcl-pi *n  varchar(MAX_PROMPT);
        connFd    int(10)      const;
        reqMethod varchar(10);
        reqPath   varchar(200);
    end-pi;

    dcl-s rawBuf  char(32767);
    dcl-s bytesRd int(10);
    dcl-s raw     varchar(32767);
    dcl-s hdrPart varchar(8192);
    dcl-s body    varchar(MAX_PROMPT);
    dcl-s hdrEnd  int(10);
    dcl-s clPos   int(10);
    dcl-s clEnd   int(10);
    dcl-s clStr   varchar(10);
    dcl-s contLen int(10)  inz(0);
    dcl-s sp1     int(10);
    dcl-s sp2     int(10);

    reqMethod = '';
    reqPath   = '';
    body      = '';

    bytesRd = sock_recv(connFd : %addr(rawBuf) : %size(rawBuf) - 1 : 0);
    if bytesRd <= 0;
        return '';
    endif;

    raw = %subst(rawBuf : 1 : bytesRd);

    hdrEnd = %scan(CRLF + CRLF : raw);
    if hdrEnd > 0;
        hdrPart = %subst(raw : 1 : hdrEnd - 1);
        if hdrEnd + 3 < %len(raw);
            body = %subst(raw : hdrEnd + 4);
        endif;
    else;
        hdrPart = raw;
    endif;

    sp1 = %scan(' ' : hdrPart);
    if sp1 > 0;
        reqMethod = %trim(%subst(hdrPart : 1 : sp1 - 1));
        sp2 = %scan(' ' : hdrPart : sp1 + 1);
        if sp2 > sp1;
            reqPath = %trim(%subst(hdrPart : sp1 + 1 : sp2 - sp1 - 1));
        endif;
    endif;

    clPos = %scan('Content-Length: ' : hdrPart);
    if clPos > 0;
        clEnd = %scan(CRLF : hdrPart : clPos);
        if clEnd > clPos;
            clStr   = %trim(%subst(hdrPart : clPos + 16 : clEnd - clPos - 16));
            contLen = %int(%trim(clStr));
        endif;
    endif;

    dow contLen > 0 and %len(body) < contLen;
        bytesRd = sock_recv(connFd : %addr(rawBuf) : %size(rawBuf) - 1 : 0);
        if bytesRd <= 0;
            leave;
        endif;
        body += %subst(rawBuf : 1 : bytesRd);
    enddo;

    return body;

end-proc readHttpRequest;

// ===========================================================================
// writeHttpResponse — sends an HTTP/1.0 response on the connected socket.
// ===========================================================================
dcl-proc writeHttpResponse;
    dcl-pi *n;
        connFd     int(10)              const;
        statusCode int(10)              const;
        body       varchar(MAX_RESPONSE) const;
    end-pi;

    dcl-s statusText varchar(30);
    dcl-s hdr        varchar(256);

    select;
        when statusCode = 200;
            statusText = 'OK';
        when statusCode = 400;
            statusText = 'Bad Request';
        when statusCode = 500;
            statusText = 'Internal Server Error';
        other;
            statusText = 'Unknown';
    endsl;

    hdr = 'HTTP/1.0 ' + %char(statusCode) + ' ' + statusText + CRLF +
          'Content-Type: application/json' + CRLF +
          'Content-Length: ' + %char(%len(body)) + CRLF +
          'Connection: close' + CRLF +
          CRLF;

    sendOnFd(connFd : hdr);
    sendOnFd(connFd : body);

end-proc writeHttpResponse;

// ===========================================================================
// jsonEscape — escapes a string for safe embedding in a JSON string value.
// ===========================================================================
dcl-proc jsonEscape;
    dcl-pi *n  varchar(MAX_RESPONSE);
        s  varchar(MAX_RESPONSE) const;
    end-pi;

    dcl-s escaped varchar(MAX_RESPONSE);
    dcl-s i       int(10);
    dcl-s ch      char(1);

    escaped = '';
    for i = 1 to %len(s);
        ch = %subst(s : i : 1);
        select;
            when ch = x'7F';               // EBCDIC double-quote
                escaped += JS_ESC_QUOTE;
            when ch = x'E0';               // EBCDIC backslash
                escaped += JS_ESC_BKSLASH;
            when ch = x'25' or ch = x'0A'; // EBCDIC NL or ASCII LF
                escaped += JS_ESC_NL;
            when ch = x'0D';               // CR
                escaped += JS_ESC_CR;
            when ch = x'05' or ch = x'09'; // EBCDIC HT or ASCII HT
                escaped += JS_ESC_TAB;
            other;
                escaped += ch;
        endsl;
    endfor;

    return escaped;

end-proc jsonEscape;

// ===========================================================================
// handleQuery — parses a POST /query body and returns a JSON response.
// ===========================================================================
dcl-proc handleQuery;
    dcl-pi *n  varchar(MAX_RESPONSE);
        body  varchar(MAX_RESPONSE) const;
    end-pi;

    dcl-s sessIdx  int(10);
    dcl-s sessId   varchar(36);
    dcl-s result   varchar(MAX_RESPONSE);
    dcl-s jsonResp varchar(MAX_RESPONSE);

    clear queryReqDs;
    monitor;
        Data-Into queryReqDs
            %Data(body : 'case=any allowextra=yes')
            %Parser('YAJLINTO');
    on-error;
        writeLog('handleQuery: JSON parse error');
        return '{"session_id":"","status":"error",' +
               '"message":"Invalid JSON body"}';
    endmon;

    if %trim(queryReqDs.q_query) = '';
        return '{"session_id":"","status":"error",' +
               '"message":"Missing query field"}';
    endif;

    if %trim(queryReqDs.q_session_id) <> '';
        sessIdx = findSession(%trim(queryReqDs.q_session_id));
        if sessIdx = 0;
            return '{"session_id":"' +
                   jsonEscape(%trim(queryReqDs.q_session_id)) +
                   '","status":"error","message":"Session not found"}';
        endif;
    else;
        sessId  = newSession();
        if sessId = '';
            return '{"session_id":"","status":"error",' +
                   '"message":"Session limit reached"}';
        endif;
        sessIdx = findSession(sessId);
    endif;

    sessId = sessions(sessIdx).sessId;
    result = runReact(sessIdx : %trim(queryReqDs.q_query));

    if sessions(sessIdx).paused;
        jsonResp = '{"session_id":"' + jsonEscape(sessId) + '",' +
                   '"status":"clarify",' +
                   '"question":"' + jsonEscape(result) + '"}';
    else;
        jsonResp = '{"session_id":"' + jsonEscape(sessId) + '",' +
                   '"status":"answer",' +
                   '"response":"' + jsonEscape(result) + '"}';
    endif;

    return jsonResp;

end-proc handleQuery;

// ===========================================================================
// serveHttp — main HTTP server accept loop (BSD sockets, HTTP/1.0).
// ===========================================================================
dcl-proc serveHttp;

    // sockaddr_in structure (16 bytes - AF_INET)
    dcl-ds sockaddrIn qualified;
        sin_family  uns(5)  inz(2);
        sin_port    uns(5)  inz(0);
        sin_addr    uns(10) inz(0);
        sin_zero    char(8) inz(*allx'00');
    end-ds;

    dcl-s listenFd  int(10);
    dcl-s connFd    int(10);
    dcl-s colonPos  int(10);
    dcl-s ifaceStr  varchar(100);
    dcl-s portStr   varchar(10);
    dcl-s portNum   int(10);
    dcl-s optVal    int(10) inz(1);
    dcl-s reqMethod varchar(10);
    dcl-s reqPath   varchar(200);
    dcl-s reqBody   varchar(MAX_PROMPT);
    dcl-s respBody  varchar(MAX_RESPONSE);
    dcl-s rc        int(10);

    colonPos = %scan(':' : listenAddr);
    if colonPos = 0;
        writeLog('serveHttp: invalid listenAddr (no colon): ' + listenAddr);
        return;
    endif;

    ifaceStr = %trim(%subst(listenAddr : 1 : colonPos - 1));
    portStr  = %trim(%subst(listenAddr : colonPos + 1));
    portNum  = %int(portStr);

    if portNum <= 0 or portNum > 65535;
        writeLog('serveHttp: invalid port: ' + portStr);
        return;
    endif;

    listenFd = sock_socket(AF_INET : SOCK_STREAM : 0);
    if listenFd < 0;
        writeLog('serveHttp: socket() failed');
        return;
    endif;

    rc = sock_setsockopt(listenFd : SOL_SOCKET : SO_REUSEADDR :
                         %addr(optVal) : %size(optVal));

    sockaddrIn.sin_family = AF_INET;
    sockaddrIn.sin_port   = sock_htons(%uns(portNum));
    if ifaceStr = '0.0.0.0' or ifaceStr = '';
        sockaddrIn.sin_addr = INADDR_ANY;
    else;
        sockaddrIn.sin_addr = sock_inet_addr(ifaceStr);
    endif;

    if sock_bind(listenFd : %addr(sockaddrIn) : %size(sockaddrIn)) < 0;
        writeLog('serveHttp: bind() failed on ' + listenAddr);
        rc = sock_close(listenFd);
        return;
    endif;

    if sock_listen(listenFd : 5) < 0;
        writeLog('serveHttp: listen() failed');
        rc = sock_close(listenFd);
        return;
    endif;

    writeLog('HTTP server listening on ' + listenAddr);

    dou *off;

        connFd = sock_accept(listenFd : *null : *null);
        if connFd < 0;
            writeLog('serveHttp: accept() failed - continuing');
            iter;
        endif;

        reqBody = readHttpRequest(connFd : reqMethod : reqPath);
        writeLog('Request: ' + %trim(reqMethod) + ' ' + %trim(reqPath));

        select;
            when %trim(reqMethod) = 'GET' and %trim(reqPath) = '/health';
                respBody = '{"status":"ok"}';
                writeHttpResponse(connFd : 200 : respBody);

            when %trim(reqMethod) = 'POST' and %trim(reqPath) = '/query';
                if reqBody = '';
                    respBody = '{"session_id":"","status":"error",' +
                               '"message":"Empty request body"}';
                    writeHttpResponse(connFd : 400 : respBody);
                else;
                    respBody = handleQuery(reqBody);
                    writeHttpResponse(connFd : 200 : respBody);
                endif;

            other;
                respBody = '{"status":"error","message":"Not found"}';
                writeHttpResponse(connFd : 400 : respBody);
        endsl;

        writeLog('Response sent for ' + %trim(reqPath));
        rc = sock_close(connFd);

    enddo;

    rc = sock_close(listenFd);

end-proc serveHttp;

// ===========================================================================
// SendProgramMessage — writes a message to the job log via QMHSNDPM.
// ===========================================================================
dcl-proc SendProgramMessage;
    dcl-pi *n;
        in_message  varchar(512) const;
    end-pi;

    dcl-s msgKey  char(4);
    dcl-s errDs   char(16) inz(*allx'00');
    dcl-s msgData char(512);

    msgData = in_message;
    SendMessage( 'CPF9898'
               : 'QCPFMSG   QSYS'
               : msgData
               : %len(%trim(in_message))
               : '*INFO'
               : '*CTLBDY'
               : 1
               : msgKey
               : errDs
               );

end-proc SendProgramMessage;
