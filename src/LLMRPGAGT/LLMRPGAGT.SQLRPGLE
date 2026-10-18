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

ctl-opt option(*srcstmt : *nodebugio : *nounref)
        bnddir('HTTPAPI' : 'YAJL');

// Five program parameters
dcl-pi *n;
    providerName  char(20)    const;   // required
    listenAddr    char(100)   const;   // required: iface:port
    mcpUrl        char(1000)  const;   // optional (blank = omitted)
    skillsPath    char(1000)  const;   // optional (blank = omitted)
    logPath       char(1000)  const;   // optional (blank = omitted)
end-pi;

// ---------------------------------------------------------------------------
// HTTPAPI / YAJL includes
// ---------------------------------------------------------------------------
/INCLUDE '/QSYS.LIB/LIBHTTP.LIB/QRPGLESRC.FILE/HTTPAPI_H.MBR'
/INCLUDE '/QSYS.LIB/YAJL.LIB/QRPGLESRC.FILE/YAJL_H.MBR'

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------
dcl-c  MAX_RESPONSE    32000;
dcl-c  MAX_RESP_PAYLOAD 16000;  // max LLM text embedded in a JSON response
dcl-c  MAX_PROMPT      16000;
dcl-c  MAX_SYSTEM      65535;
dcl-c  MAX_SKILLS      65535;
dcl-c  MAX_LOG_MSG     4096;
dcl-c  MAX_SESSIONS    100;
dcl-c  MAX_MCP_TOOLS   50;
dcl-c  MAX_REACT_STEPS 10;
dcl-c  NL              x'25';    // EBCDIC newline / IFS LF
dcl-c  CRLF            x'0D0A';  // HTTP line ending (ASCII CR+LF for wire protocol)
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
dcl-pr c_open3  int(10) extproc('open');
    path        pointer value options(*string);
    flags       int(10) value;
    mode        uns(10) value;
end-pr;

dcl-pr c_write  int(10) extproc('write');
    fd          int(10) value;
    buf         pointer value;
    nbytes      uns(10) value;
end-pr;

// open() flag constants (IBM i IFS native values from QSYSINC/H,FCNTL)
dcl-c  O_WRONLY   2;
dcl-c  O_CREAT    8;
dcl-c  O_APPEND   256;
dcl-c  S_IRUSR    256;
dcl-c  S_IWUSR    128;
dcl-c  S_IRGRP    32;
dcl-c  S_IROTH    4;

// ---------------------------------------------------------------------------
// PASE C prototypes — IFS stream file read (skills file)
// ---------------------------------------------------------------------------
dcl-pr c_fopen  pointer extproc('fopen');
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
dcl-c  SOL_SOCKET   65535;  // 0xffff — correct PASE value for setsockopt level
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
// YAJLINTO flattens nested objects so DS field names must match JSON leaf
// keys exactly.  countprefix=num_ generates num_<fieldname> counters, so
// the count field must be named num_name (matches the "name" array field).
// ---------------------------------------------------------------------------
dcl-ds mcpListParse qualified;
    num_name     int(10)       inz(0);   // populated by countprefix=num_ for "name"
    name         varchar(200)  dim(MAX_MCP_TOOLS);
    description  varchar(1000) dim(MAX_MCP_TOOLS);
end-ds;

// Flat DS for parsing MCP tools/call JSON response.
// JSON shape: {"result":{"content":[{"type":"text","text":"..."}]}}
// DS field names must match JSON keys exactly: "type" and "text".
// countprefix=num_ generates num_type for the "type" array.
dcl-ds mcpCallParse qualified;
    num_type     int(10)           inz(0);   // populated by countprefix=num_ for "type"
    type         varchar(50)       dim(10);
    text         varchar(MAX_RESPONSE) dim(10);
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
// Parameters are char (CL *CHAR); blank = omitted.  %trim() is safe on char.
openLog(%trim(logPath));

SendProgramMessage('LLMRPGAGT starting.');
writeLog('LLMRPGAGT starting.');
writeLog('Provider: ' + %trim(providerName));
writeLog('Listen:   ' + %trim(listenAddr));

// 2. Bootstrap LLM provider config
backend = %trim(providerName);
fetchConfig();
setForJob();
writeLog('LLM provider configured: ' + backend);

// 3. Connect to MCP server (optional)
if %trim(mcpUrl) <> '';
    g_mcpUrl = %trim(mcpUrl);
    // Warn if URL is missing an http:// or https:// scheme; HTTPAPI requires
    // a fully-qualified URL (e.g. 'http://127.0.0.1:8020').
    if %scan('://' : g_mcpUrl) = 0;
        writeLog('WARNING: MCPURL has no scheme (http:// or https://). ' +
                 'Prepending http://. Supplied: ' + g_mcpUrl);
        SendProgramMessage('LLMRPGAGT: MCPURL missing scheme - prepending http://');
        g_mcpUrl = 'http://' + g_mcpUrl;
    endif;
    writeLog('Connecting to MCP server: ' + g_mcpUrl);
    fetchMcpTools(g_mcpUrl);
    writeLog('MCP tools loaded: ' + %char(mcpToolCount));
else;
    writeLog('No MCP server specified - tool calls disabled.');
endif;

// 4. Load skills file (optional)
if %trim(skillsPath) <> '';
    writeLog('Loading skills file: ' + %trim(skillsPath));
    loadSkills(%trim(skillsPath));
else;
    writeLog('No skills file specified.');
endif;

// 5. Build system prompt
buildSystemPrompt();
writeLog('System prompt built (' + %char(%len(systemPrompt)) + ' chars).');

// 6. Start HTTP server
writeLog('Starting HTTP server on ' + %trim(listenAddr) + ' ...');
SendProgramMessage('LLMRPGAGT: starting HTTP server on ' + %trim(listenAddr));
serveHttp();

SendProgramMessage('LLMRPGAGT: HTTP server exited.');
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
// Delegates to callOpenAI or callOllama; contains no SQL itself so that the
// SQL precompiler does not generate host-variable descriptors that could set
// SQLCODE on the ollama path.
// ===========================================================================
dcl-proc callLLM;
    dcl-pi *n  varchar(MAX_RESPONSE);
        in_prompt  varchar(MAX_PROMPT) const;
    end-pi;

    if backend = 'openai_compatible';
        return callOpenAI(in_prompt);
    else;
        writeLog('callLLM(ollama): promptLen=' + %char(%len(%trim(in_prompt))));
        return callOllama(in_prompt);
    endif;

    return '';

end-proc callLLM;

// ===========================================================================
// callOpenAI — calls dbsdk_v1.openai_compatible_chat_generate via embedded
// SQL.  Isolated in its own procedure so that its ccsid 1208 host variables
// and Exec SQL statements are invisible to callLLM when the ollama backend
// is selected.
// ===========================================================================
dcl-proc callOpenAI;
    dcl-pi *n  varchar(MAX_RESPONSE);
        in_prompt  varchar(MAX_PROMPT) const;
    end-pi;

    dcl-s llmResponse  varchar(MAX_RESPONSE) ccsid 1208;
    dcl-s promptOai    varchar(32000)        ccsid 1208;

    writeLog('callLLM(openai_compatible): promptLen=' +
             %char(%len(%trim(in_prompt))));

    promptOai = %trim(in_prompt);

    Exec SQL
        SET :llmResponse = (
            VALUES dbsdk_v1.openai_compatible_chat_generate(
                prompt   => :promptOai,
                options  => '{}' )
        );

    if sqlcode <> 0;
        writeLog('callOpenAI: openai_compatible_chat_generate error sqlcode=' +
                 %char(sqlcode));
        return 'ANSWER: Error calling LLM (sqlcode=' + %char(sqlcode) + ')';
    endif;

    writeLog('callLLM(openai_compatible): responseLen=' +
             %char(%len(llmResponse)));

    return llmResponse;

end-proc callOpenAI;

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
// body is sized at 32767 to accommodate JSON-escaped prompts (up to 32000
// chars from jsonEscape) plus the JSON envelope overhead.
// ===========================================================================
dcl-proc httpPost;
    dcl-pi *n  varchar(MAX_RESPONSE);
        url   varchar(1000)    const;
        body  varchar(32767)   const;
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
// callOllama — calls the Ollama /api/generate endpoint directly via HTTPAPI,
// bypassing dbsdk_v1.ollama_generate whose varchar(1000) prompt cap is too
// small for a ReAct system prompt + conversation history.
// Uses the same g_server / g_port / protocol / model globals as setForJob().
// Returns the response text, or an error string prefixed with 'ANSWER: '.
// ===========================================================================
dcl-proc callOllama;
    dcl-pi *n  varchar(MAX_RESPONSE);
        in_prompt  varchar(MAX_PROMPT) const;
    end-pi;

    dcl-s url        varchar(1000);
    // reqBody must hold the JSON envelope plus the JSON-escaped prompt.
    // jsonEscape returns up to MAX_RESPONSE (32000) chars in the worst case,
    // plus ~60 chars of JSON framing, so 32767 is the safe ceiling.
    dcl-s reqBody    varchar(32767);
    dcl-s response   varchar(MAX_RESPONSE);
    dcl-s rtnVal     varchar(MAX_RESPONSE);

    url = %trim(protocol) + '://' + %trim(g_server) + ':' +
          %trim(%editc(g_port : 'X')) + '/api/generate';

    reqBody = '{"model":"'  + jsonEscape(%trim(model))  + '",' +
              '"prompt":"'  + jsonEscape(%trim(in_prompt)) + '",' +
              '"stream":false}';

    response = httpPost(url : reqBody);

    if response = '';
        writeLog('callOllama: no response from Ollama server.');
        return 'ANSWER: Error calling LLM (no response from Ollama)';
    endif;

    rtnVal = extractJsonStr(response : 'response');

    if rtnVal = '';
        writeLog('callOllama: could not parse response field - returning raw');
        return response;
    endif;

    return rtnVal;

end-proc callOllama;

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

    for i = 1 to mcpListParse.num_name;
        if i > MAX_MCP_TOOLS;
            leave;
        endif;
        mcpTools(i).toolName = mcpListParse.name(i);
        mcpTools(i).toolDesc = mcpListParse.description(i);
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
    for i = 1 to mcpCallParse.num_type;
        if mcpCallParse.type(i) = 'text';
            if rtnVal <> '';
                rtnVal += NL;
            endif;
            rtnVal += mcpCallParse.text(i);
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
    dcl-s sysLen      int(10);   // clamped system-prompt length
    dcl-s histLen     int(10);   // remaining chars for history
    dcl-s llmOut      varchar(MAX_RESPONSE);
    dcl-s action      varchar(200);
    dcl-s actionInput varchar(4096);
    dcl-s clarify     varchar(4096);
    dcl-s answer      varchar(MAX_RESPONSE);
    dcl-s toolResult  varchar(MAX_RESPONSE);
    dcl-s step        int(10);
    dcl-s histMax     int(10)  inz(65535);  // max length of history field
    dcl-s appendStr   varchar(MAX_RESPONSE);
    dcl-s appendLen   int(20);              // needs int(20): hist(65535)+llm(32000)

    // history += 'User: ' + userInput + NL — guard against overflow
    appendStr = 'User: ' + %subst(userInput : 1 :
                    %min(%len(userInput) : MAX_PROMPT)) + NL;
    appendLen = %len(sessions(sessIdx).history) + %len(appendStr);
    if appendLen <= histMax;
        sessions(sessIdx).history += appendStr;
    else;
        writeLog('runReact: history full - user entry dropped');
    endif;
    sessions(sessIdx).paused   = *off;
    sessions(sessIdx).done     = *off;

    for step = 1 to MAX_REACT_STEPS;

        sessions(sessIdx).stepNum = step;

        // Clamp systemPrompt + history to MAX_PROMPT before assigning to
        // fullPrompt.  All branches use %subst on both components so that the
        // RHS expression never exceeds MAX_PROMPT chars — direct concatenation
        // of varchar(65535) fields into a varchar(16000) target causes RNQ0115.
        sysLen  = %min(%len(systemPrompt) : MAX_PROMPT - 2);
        histLen = MAX_PROMPT - sysLen - 2;  // 2 = two NL separators
        fullPrompt = %subst(systemPrompt : 1 : sysLen) + NL + NL;
        if histLen > 0;
            if %len(sessions(sessIdx).history) <= histLen;
                fullPrompt += %subst(sessions(sessIdx).history : 1 :
                                     %len(sessions(sessIdx).history));
            else;
                fullPrompt +=
                    %subst(sessions(sessIdx).history :
                           %len(sessions(sessIdx).history) - histLen + 1);
            endif;
        endif;

        writeLog('ReAct step ' + %char(step) +
                 ' session ' + sessions(sessIdx).sessId);

        llmOut = callLLM(fullPrompt);
        // history += 'Assistant: ' + llmOut + NL — append in pieces to avoid
        // constructing a temporary expression larger than varchar(65535).
        appendLen = %len(sessions(sessIdx).history) + 11 +  // 'Assistant: '
                    %len(llmOut) + 1;                        // + NL
        if appendLen <= histMax;
            sessions(sessIdx).history += 'Assistant: ';
            sessions(sessIdx).history += llmOut;
            sessions(sessIdx).history += NL;
        else;
            writeLog('runReact: history full - assistant entry dropped');
        endif;

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

            // history += 'Tool(...): ' + toolResult + NL — append in pieces
            appendStr = 'Tool(' + %trim(action) + '): ';
            appendLen = %len(sessions(sessIdx).history) + %len(appendStr) +
                        %len(toolResult) + 1;
            if appendLen <= histMax;
                sessions(sessIdx).history += appendStr;
                sessions(sessIdx).history += toolResult;
                sessions(sessIdx).history += NL;
            else;
                writeLog('runReact: history full - tool entry dropped');
            endif;

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

    // Translate EBCDIC data to ASCII (CCSID 819) before sending over the wire.
    // asciiBuf: assignment from EBCDIC varchar triggers EBCDIC->ASCII conversion.
    // wireBuf:  also CCSID(819) so no re-translation occurs on the char copy.
    dcl-s asciiBuf  varchar(MAX_SYSTEM) ccsid(819);
    dcl-s wireBuf   char(MAX_SYSTEM)    ccsid(819);
    dcl-s len       uns(10);
    dcl-s rc        int(10);

    asciiBuf = data;           // EBCDIC -> ASCII translation happens here
    len = %uns(%len(asciiBuf));
    if len = 0;
        return;
    endif;
    wireBuf = asciiBuf;        // no-op copy: both are CCSID 819
    rc  = sock_send(fd : %addr(wireBuf) : len : 0);

end-proc sendOnFd;

// ===========================================================================
// sendOnFdRaw — sends pre-encoded ASCII data on a socket fd without any
// CCSID conversion.  Used for HTTP response headers already in CCSID 819.
// ===========================================================================
dcl-proc sendOnFdRaw;
    dcl-pi *n;
        fd    int(10)              const;
        data  varchar(MAX_SYSTEM)  ccsid(819) const;
    end-pi;

    dcl-s wireBuf  char(MAX_SYSTEM) ccsid(819);
    dcl-s len      uns(10);
    dcl-s rc       int(10);

    len = %uns(%len(data));
    if len = 0;
        return;
    endif;
    wireBuf = data;   // same CCSID — no conversion
    rc = sock_send(fd : %addr(wireBuf) : len : 0);

end-proc sendOnFdRaw;

// ===========================================================================
// readHttpRequest — reads one HTTP request from a connected socket fd.
// Returns the body; sets reqMethod and reqPath as output parameters.
// ===========================================================================
dcl-proc readHttpRequest;
    dcl-pi *n  varchar(MAX_RESPONSE);
        connFd    int(10)      const;
        reqMethod varchar(10);
        reqPath   varchar(200);
    end-pi;

    // rawBuf is tagged CCSID(819) so sock_recv bytes are treated as ASCII.
    // Assigning rawBuf slices to raw/hdrPart (also CCSID 819) is a no-op copy.
    // Assigning a CCSID(819) slice to plain varchar triggers ASCII->EBCDIC
    // conversion, which is what we want — YAJLINTO requires EBCDIC input.
    dcl-s rawBuf  char(32767) ccsid(819);
    dcl-s bytesRd int(10);
    dcl-s raw     varchar(32767) ccsid(819);
    dcl-s hdrPart varchar(8192)  ccsid(819);
    dcl-s rawBody varchar(32767) ccsid(819);  // body slice before CCSID convert
    dcl-s bodyLen int(10);                    // capped body byte count
    dcl-s body    varchar(MAX_RESPONSE);
    dcl-s hdrEnd  int(10);
    dcl-s clPos   int(10);
    dcl-s clEnd   int(10);
    dcl-s clStr       varchar(10);
    dcl-s contLen     int(10)  inz(0);
    dcl-s sp1         int(10);
    dcl-s sp2         int(10);
    // All strings scanned against ccsid(819) buffers must themselves be
    // ccsid(819); EBCDIC literals would never match ASCII wire bytes.
    dcl-s aCRLF       char(2)    ccsid(819) inz(x'0D0A');
    dcl-s aSP         char(1)    ccsid(819) inz(' ');
    dcl-s clHeader    varchar(16) ccsid(819) inz('Content-Length: ');

    reqMethod = '';
    reqPath   = '';
    body      = '';

    bytesRd = sock_recv(connFd : %addr(rawBuf) : %size(rawBuf) - 1 : 0);
    if bytesRd <= 0;
        return '';
    endif;

    raw = %subst(rawBuf : 1 : bytesRd);

    hdrEnd = %scan(aCRLF + aCRLF : raw);
    if hdrEnd > 0;
        hdrPart = %subst(raw : 1 : hdrEnd - 1);
        if hdrEnd + 3 < %len(raw);
            // Extract body slice into same-width ccsid(819) buffer first,
            // then copy with an explicit length that fits MAX_RESPONSE.
            // This avoids the compiler inserting a truncation-check when
            // assigning varchar(32767) directly to varchar(32000).
            bodyLen = %min(%len(raw) - hdrEnd - 3 : MAX_RESPONSE);
            rawBody = %subst(raw : hdrEnd + 4 : bodyLen);
            body    = %subst(rawBody : 1 : bodyLen);
        endif;
    else;
        hdrPart = raw;
    endif;

    sp1 = %scan(aSP : hdrPart);
    if sp1 > 0;
        reqMethod = %trim(%subst(hdrPart : 1 : sp1 - 1));
        sp2 = %scan(aSP : hdrPart : sp1 + 1);
        if sp2 > sp1;
            reqPath = %trim(%subst(hdrPart : sp1 + 1 : sp2 - sp1 - 1));
        endif;
    endif;

    clPos = %scan(clHeader : hdrPart);
    if clPos > 0;
        clEnd = %scan(aCRLF : hdrPart : clPos);
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
        // Stage through rawBody (varchar(32767) ccsid(819)) before converting
        // to body (plain varchar) to avoid compiler truncation-check on the
        // varchar(32767)->varchar(32000) width mismatch.
        bodyLen = %min(bytesRd : MAX_RESPONSE - %len(body));
        if bodyLen <= 0;
            leave;
        endif;
        rawBody = %subst(rawBuf : 1 : bodyLen);
        body   += %subst(rawBody : 1 : bodyLen);
    enddo;

    writeLog('readHttpRequest: hdrEnd=' + %char(hdrEnd) +
             ' contLen=' + %char(contLen) +
             ' bodyLen=' + %char(%len(body)) +
             ' body=[' + %subst(body + ' ' : 1 : %min(80 : %len(body + ' '))) + ']');
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

    // Build header directly in CCSID 819 (ASCII) so CRLF bytes are never
    // subject to EBCDIC->ASCII translation.  All header text characters
    // (A-Z, 0-9, space, hyphen, slash, colon) are invariant between EBCDIC
    // and ASCII so the string literal assignments translate correctly.
    // x'0D0A' written into a ccsid(819) var is stored as-is (no conversion).
    dcl-c  CRLF_A   x'0D0A';           // ASCII CR+LF — used only here
    dcl-s statusText varchar(30)        ccsid(819);
    dcl-s hdr        varchar(512)       ccsid(819);
    dcl-s bodyLen    varchar(10);       // decimal digits — ASCII-invariant

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

    bodyLen = %char(%len(body));        // EBCDIC digits -> ccsid(819): safe

    hdr = 'HTTP/1.0 ' + %char(statusCode) + ' ' + statusText + CRLF_A +
          'Content-Type: application/json' + CRLF_A +
          'Content-Length: ' + bodyLen + CRLF_A +
          'Connection: close' + CRLF_A +
          CRLF_A;

    sendOnFdRaw(connFd : hdr);          // already ASCII — send without conversion
    sendOnFd(connFd : body);            // EBCDIC body — sendOnFd converts to ASCII

end-proc writeHttpResponse;

// ===========================================================================
// jsonEscape — escapes a string for safe embedding in a JSON string value.
// ===========================================================================
dcl-proc jsonEscape;
    dcl-pi *n  varchar(MAX_RESPONSE);
        s  varchar(MAX_RESPONSE) const;
    end-pi;

    // worst-case every byte doubles (e.g. all backslashes); use 32767 ceiling
    dcl-s escaped varchar(32767);
    dcl-s i       int(10);
    dcl-s ch      char(1);

    escaped = '';
    monitor;
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
    on-error;
        // truncated due to response size; return what fit
        writeLog('jsonEscape: output truncated at ' + %char(%len(escaped)) +
                 ' chars (input was ' + %char(%len(s)) + ')');
    endmon;

    return %subst(escaped : 1 : %min(%len(escaped) : MAX_RESPONSE));

end-proc jsonEscape;

// ===========================================================================
// extractJsonStr — extracts the string value of a named key from a flat
// EBCDIC JSON object.  Handles only string values; returns '' if not found.
// Walks the key-colon-quote-value-quote pattern byte by byte so it handles
// escaped quotes (\" = x'E07F') inside values without a full JSON parser.
// ===========================================================================
dcl-proc extractJsonStr;
    dcl-pi *n  varchar(MAX_PROMPT);
        doc  varchar(MAX_RESPONSE) const;  // EBCDIC JSON body
        key  varchar(200)          const;  // key name to find (without quotes)
    end-pi;

    // EBCDIC single characters used for scanning
    dcl-c DQUOTE  x'7F';   // "
    dcl-c COLON   x'7A';   // :
    dcl-c BKSLASH x'E0';   // \

    dcl-s searchKey  varchar(202);
    dcl-s keyPos     int(10);
    dcl-s valStart   int(10);
    dcl-s i          int(10);
    dcl-s ch         char(1);
    dcl-s prevCh     char(1);
    dcl-s value      varchar(MAX_PROMPT);

    // Build "key" pattern to locate in doc
    searchKey = DQUOTE + key + DQUOTE;
    keyPos = %scan(searchKey : doc);
    if keyPos = 0;
        return '';
    endif;

    // Skip past the key and its closing quote to find the colon
    valStart = keyPos + %len(searchKey);
    // Skip whitespace and the colon
    dou valStart > %len(doc);
        ch = %subst(doc : valStart : 1);
        if ch = COLON;
            valStart += 1;
            leave;
        endif;
        valStart += 1;
    enddo;
    // Skip whitespace to opening quote of value
    dou valStart > %len(doc);
        ch = %subst(doc : valStart : 1);
        if ch = DQUOTE;
            valStart += 1;  // step past opening quote
            leave;
        endif;
        valStart += 1;
    enddo;
    if valStart > %len(doc);
        return '';
    endif;

    // Collect value bytes until unescaped closing quote
    value   = '';
    prevCh  = x'00';
    for i = valStart to %len(doc);
        ch = %subst(doc : i : 1);
        if ch = DQUOTE and prevCh <> BKSLASH;
            leave;  // unescaped closing quote — done
        endif;
        value  += ch;
        prevCh  = ch;
    endfor;

    return value;

end-proc extractJsonStr;

// ===========================================================================
// handleQuery — parses a POST /query body and returns a JSON response.
// Uses extractJsonStr instead of DATA-INTO/YAJLINTO for the simple two-field
// request body {"session_id":"...","query":"..."}.
// ===========================================================================
dcl-proc handleQuery;
    dcl-pi *n  varchar(MAX_RESPONSE);
        body  varchar(MAX_RESPONSE) const;
    end-pi;

    dcl-s sessIdx       int(10);
    dcl-s sessId        varchar(36);
    dcl-s rawResult     varchar(MAX_RESPONSE);     // raw return from runReact
    dcl-s result        varchar(MAX_RESP_PAYLOAD); // capped at escape-safe size
    dcl-s escapedResult varchar(32767);            // jsonEscape output buffer
    dcl-s jsonResp      varchar(MAX_RESPONSE);
    dcl-s queryVal      varchar(MAX_PROMPT);
    dcl-s sessRaw       varchar(MAX_PROMPT);       // raw session_id from JSON
    dcl-s sessionVal    varchar(36);

    // Validate outer object — check first non-space byte is EBCDIC '{'
    if %len(%trim(body)) = 0 or %subst(%trim(body) : 1 : 1) <> x'C0';
        writeLog('handleQuery: body does not start with { — invalid JSON');
        return '{"session_id":"","status":"error",' +
               '"message":"Invalid JSON body"}';
    endif;

    queryVal = extractJsonStr(body : 'query');
    // Pad sessRaw to at least 36 chars before %subst to guarantee the
    // length argument is in range even when session_id is absent.
    sessRaw = extractJsonStr(body : 'session_id');
    if %len(sessRaw) < 36;
        sessRaw = sessRaw + %subst('                                    '
                                   : 1 : 36 - %len(sessRaw));
    endif;
    sessionVal = %subst(sessRaw : 1 : 36);
    writeLog('handleQuery: queryLen=' + %char(%len(%trim(queryVal))) +
             ' sessionVal=[' + %trim(sessionVal) + ']');

    if %trim(queryVal) = '';
        return '{"session_id":"","status":"error",' +
               '"message":"Missing query field"}';
    endif;

    if %trim(sessionVal) <> '';
        sessIdx = findSession(%trim(sessionVal));
        if sessIdx = 0;
            return '{"session_id":"' +
                   jsonEscape(%trim(sessionVal)) +
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

    // Assign runReact result safely: runReact returns varchar(MAX_RESPONSE)
    // but result is varchar(MAX_RESP_PAYLOAD).  Use %subst to cap without
    // relying on implicit truncation (which throws RNX0100).
    rawResult = runReact(sessIdx : %trim(queryVal));
    if %len(rawResult) > MAX_RESP_PAYLOAD;
        writeLog('handleQuery: result truncated from ' +
                 %char(%len(rawResult)) + ' to ' +
                 %char(MAX_RESP_PAYLOAD) + ' chars');
        result = %subst(rawResult : 1 : MAX_RESP_PAYLOAD);
    else;
        result = rawResult;
    endif;

    // JSON-escape the result into a dedicated buffer sized for worst-case
    // doubling (16000 chars * 2 = 32000, well within varchar(32767)).
    escapedResult = jsonEscape(result);

    // Build the JSON response.  All pieces are now bounded:
    //   sessId        <=  36 chars  (UUID)
    //   escapedResult <= 32000 chars
    //   envelope      ~   60 chars
    //   total         <= 32096 chars — fits in varchar(MAX_RESPONSE=32000)
    // Trim escapedResult to leave room for the envelope if needed.
    if %len(escapedResult) > 31900;
        escapedResult = %subst(escapedResult : 1 : 31900);
    endif;

    if sessions(sessIdx).paused;
        jsonResp = '{"session_id":"' + sessId + '",' +
                   '"status":"clarify",' +
                   '"question":"'  + escapedResult + '"}';
    else;
        jsonResp = '{"session_id":"' + sessId + '",' +
                   '"status":"answer",' +
                   '"response":"' + escapedResult + '"}';
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
    dcl-s reqBody   varchar(MAX_RESPONSE);
    dcl-s respBody  varchar(MAX_RESPONSE);
    dcl-s rc        int(10);

    colonPos = %scan(':' : listenAddr);
    if colonPos = 0;
        writeLog('serveHttp: invalid listenAddr (no colon): ' + listenAddr);
        SendProgramMessage('LLMRPGAGT: invalid listenAddr: ' + %trim(listenAddr));
        return;
    endif;

    ifaceStr = %trim(%subst(listenAddr : 1 : colonPos - 1));
    portStr  = %trim(%subst(listenAddr : colonPos + 1));
    portNum  = %int(portStr);

    if portNum <= 0 or portNum > 65535;
        writeLog('serveHttp: invalid port: ' + portStr);
        SendProgramMessage('LLMRPGAGT: invalid port: ' + %trim(portStr));
        return;
    endif;

    listenFd = sock_socket(AF_INET : SOCK_STREAM : 0);
    if listenFd < 0;
        writeLog('serveHttp: socket() failed');
        SendProgramMessage('LLMRPGAGT: socket() failed');
        return;
    endif;

    rc = sock_setsockopt(listenFd : SOL_SOCKET : SO_REUSEADDR :
                         %addr(optVal) : %size(optVal));

    // inet_addr() only handles dotted-decimal; map known hostnames first.
    if ifaceStr = 'localhost';
        ifaceStr = '127.0.0.1';
    endif;

    sockaddrIn.sin_family = AF_INET;
    sockaddrIn.sin_port   = %uns(portNum);   // IBM i is big-endian; htons is a no-op
    if ifaceStr = '0.0.0.0' or ifaceStr = '';
        sockaddrIn.sin_addr = INADDR_ANY;
    else;
        sockaddrIn.sin_addr = sock_inet_addr(ifaceStr);
    endif;

    SendProgramMessage('LLMRPGAGT: binding ' + %trim(ifaceStr) +
                       ':' + %trim(portStr) +
                       ' fd=' + %char(listenFd));

    if sock_bind(listenFd : %addr(sockaddrIn) : %size(sockaddrIn)) < 0;
        writeLog('serveHttp: bind() failed on ' + listenAddr);
        SendProgramMessage('LLMRPGAGT: bind() failed on ' + %trim(listenAddr));
        rc = sock_close(listenFd);
        return;
    endif;

    if sock_listen(listenFd : 5) < 0;
        writeLog('serveHttp: listen() failed');
        SendProgramMessage('LLMRPGAGT: listen() failed');
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
                    monitor;
                        respBody = handleQuery(reqBody);
                    on-error;
                        writeLog('serveHttp: unhandled exception in handleQuery');
                        respBody = '{"session_id":"","status":"error",' +
                                   '"message":"Internal server error"}';
                    endmon;
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
