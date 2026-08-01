**free

ctl-opt dftactgrp(*no) option(*srcstmt : *nodebugio);


dcl-f  LLMDSPF  workstn
                infds(dspf_info)  indds(dspf_inds)
                sfile(PROMPTSFL : rrn1);

dcl-ds  dspf_info;
    keyPressed    char(1)  pos(369);
end-ds;

dcl-ds  dspf_inds;
    sfl_dsp        ind  pos(1);
    sfl_dspCtl     ind  pos(2);
    sfl_end        ind  pos(3);
    // Protect indicators: 20=backend, 21=protocol, 22=server, 23=port,
    //                     24=model, 25=apikey, 26=basepath
    pos_bknd       ind  pos(20);
    pos_prot       ind  pos(21);
    pos_srvr       ind  pos(22);
    pos_port       ind  pos(23);
    pos_modl       ind  pos(24);
    pos_akey       ind  pos(25);
    pos_path       ind  pos(26);
    // Change indicators: 30=backend, 31=protocol, 32=server, 33=port,
    //                    34=model, 35=apikey, 36=basepath
    chg_bknd       ind  pos(30);
    chg_prot       ind  pos(31);
    chg_srvr       ind  pos(32);
    chg_port       ind  pos(33);
    chg_modl       ind  pos(34);
    chg_akey       ind  pos(35);
    chg_path       ind  pos(36);
end-ds;

dcl-s  rrn1      uns(5);

dcl-ds PSDS PSDS;
    pgmName       *PROC;
end-ds;

dcl-c  F3       x'33';
dcl-c  F4       x'34';
dcl-c  F6       x'36';
dcl-c  F9       x'39';
dcl-c  F12      x'3C';
dcl-c  ENTER    x'F1';

// Global variables mirroring the SQL global variables for each backend.
// 'backend' drives which set of dbsdk_v1 functions are used.
dcl-s backend   varchar(20)   inz('ollama');
dcl-s protocol  varchar(10);
dcl-s server    varchar(1000);
dcl-s port      int(10);
dcl-s model     varchar(1000);
// openai_compatible extras
dcl-s apikey    varchar(8000);
dcl-s basepath  varchar(1000);

Exec SQL SET OPTION
    COMMIT=*NONE,
    DATFMT=*ISO,
    NAMING=*SYS;

// -----------------------------------------------------------------------
// Mainline
// -----------------------------------------------------------------------
fetchConfig();
setForJob();

dou keyPressed = F3;

    RUN_BKND = backend;

    RUN_URL = %trim(protocol) + '://';
    if %len(%trim(server)) > 50;
        RUN_URL = %trim(RUN_URL) + %subst(server : 1 : 50) + '[...]';
    else;
        RUN_URL = %trim(RUN_URL) + %trim(server);
    endif;
    RUN_URL = %trim(RUN_URL) + ':' + %char(port);
    RUN_MODL = model;

    write MSGSFLC;
    exfmt RUNSCRN;
    ClearProgramMessages(1);

    if keyPressed = F3;
        iter;

    elseif keyPressed = F4;
        editConfig();

    elseif keyPressed = ENTER;
        RESPONSE = callLLM( PROMPT );

    endif;

enddo;

*inlr = *on;


//------------------------------------------------------------------------------
// fetchConfig
// Reads configuration for the current backend into the global variables.
//------------------------------------------------------------------------------
dcl-proc fetchConfig;

    if backend = 'openai_compatible';

        Exec SQL
            SET :protocol = ( VALUES dbsdk_v1.openai_compatible_getprotocol() );

        Exec SQL
            SET :server = ( VALUES dbsdk_v1.openai_compatible_getserver() );

        Exec SQL
            SET :port = ( VALUES dbsdk_v1.openai_compatible_getport() );

        Exec SQL
            SET :model = ( VALUES dbsdk_v1.openai_compatible_getmodel() );

        Exec SQL
            SET :apikey = ( VALUES dbsdk_v1.openai_compatible_getapikey() );

        Exec SQL
            SET :basepath = ( VALUES dbsdk_v1.openai_compatible_getbasepath() );

    else;
        // Default: ollama

        Exec SQL
            SET :protocol = ( VALUES dbsdk_v1.ollama_getprotocol() );

        Exec SQL
            SET :server = ( VALUES dbsdk_v1.ollama_getserver() );

        Exec SQL
            SET :port = ( VALUES dbsdk_v1.ollama_getport() );

        Exec SQL
            SET :model = ( VALUES dbsdk_v1.ollama_getmodel() );

        // Not used for ollama — clear them
        apikey   = '';
        basepath = '';

    endif;

    return;
end-proc fetchConfig;



//------------------------------------------------------------------------------
// setForJob
// Pushes the global variables into the SQL job-level globals for the
// current backend, so that generate functions pick them up automatically.
//------------------------------------------------------------------------------
dcl-proc setForJob;

    if backend = 'openai_compatible';

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setprotocolforjob(
                protocol => TRIM(:protocol) );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setserverforjob(
                hostname => TRIM(:server) );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setportforjob(
                port => :port );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setmodelforjob(
                model => TRIM(:model) );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setapikeyforjob(
                api_key => TRIM(:apikey) );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setbasepathforjob(
                base_path => TRIM(:basepath) );

    else;
        // Default: ollama

        Exec SQL
            CALL dbsdk_v1.ollama_setprotocolforjob(
                protocol => TRIM(:protocol) );

        Exec SQL
            CALL dbsdk_v1.ollama_setserverforjob(
                hostname => TRIM(:server) );

        Exec SQL
            CALL dbsdk_v1.ollama_setportforjob(
                port => :port );

        Exec SQL
            CALL dbsdk_v1.ollama_setmodelforjob(
                model => TRIM(:model) );

    endif;

    SendProgramMessage('Job defaults have been set.');

    return;
end-proc setForJob;



//------------------------------------------------------------------------------
// setMyDefaults
// Persists the current global variables as the user's saved defaults
// for the current backend.
//------------------------------------------------------------------------------
dcl-proc setMyDefaults;

    if backend = 'openai_compatible';

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setprotocolforme(
                protocol => TRIM(:protocol) );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setserverforme(
                hostname => TRIM(:server) );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setportforme(
                port => :port );

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setmodelforme(
                model => TRIM(:model) );

        // Only save API key if the user typed a real value (not the mask)
        if apikey <> '********';
            Exec SQL
                CALL dbsdk_v1.openai_compatible_setapikeyforme(
                    api_key => TRIM(:apikey) );
        endif;

        Exec SQL
            CALL dbsdk_v1.openai_compatible_setbasepathforme(
                base_path => TRIM(:basepath) );

    else;
        // Default: ollama

        Exec SQL
            CALL dbsdk_v1.ollama_setprotocolforme(
                protocol => TRIM(:protocol) );

        Exec SQL
            CALL dbsdk_v1.ollama_setserverforme(
                hostname => TRIM(:server) );

        Exec SQL
            CALL dbsdk_v1.ollama_setportforme(
                port => :port );

        Exec SQL
            CALL dbsdk_v1.ollama_setmodelforme(
                model => TRIM(:model) );

    endif;

    return;
end-proc setMyDefaults;



//------------------------------------------------------------------------------
// editConfig
// First config screen: lets the user select the backend, then routes to
// the backend-specific config sub-screen.
//------------------------------------------------------------------------------
dcl-proc editConfig;

    dcl-s done      ind;
    dcl-s rtnShort  varchar(227);
    dcl-s rtnLong   varchar(1000);

    CFG_BKND = backend;

    dou done;

        write MSGSFLC;
        exfmt CFGSCRN;
        ClearProgramMessages(2);
        clear pos_bknd;

        if keyPressed = F12 or keyPressed = F3;
            keyPressed = F12;
            done = *on;

        elseif keyPressed = F4;
            if CURFLD = 'CFG_BKND';
                pos_bknd = *on;
                promptField('backend' : CFG_BKND : rtnShort : rtnLong);
                CFG_BKND = rtnShort;
            endif;

        elseif keyPressed = F6;
            backend = %trim(CFG_BKND);
            fetchConfig();
            setMyDefaults();
            SendProgramMessage('User defaults have been updated.');

        elseif keyPressed = ENTER;
            backend = %trim(CFG_BKND);
            fetchConfig();
            done = *on;
            // Open the backend-specific sub-screen
            if backend = 'openai_compatible';
                editOAIConfig();
            else;
                editOllamaConfig();
            endif;

        endif;

    enddo;

    return;
end-proc editConfig;



//------------------------------------------------------------------------------
// editOllamaConfig
// Config sub-screen for the ollama backend.
//------------------------------------------------------------------------------
dcl-proc editOllamaConfig;

    dcl-s done      ind;
    dcl-s rtnShort  varchar(227);
    dcl-s rtnLong   varchar(1000);

    OL_PROT  = protocol;
    OL_SRVR  = server;
    OL_SRVRH = server;
    OL_PORT  = %char(port);
    OL_MODL  = model;
    OL_MODLH = model;

    dou done;

        write MSGSFLC;
        exfmt OLLAMACFG;
        ClearProgramMessages(2);
        clear pos_prot;
        clear pos_srvr;
        clear pos_port;
        clear pos_modl;

        if keyPressed = F12 or keyPressed = F3;
            keyPressed = F12;
            done = *on;

        elseif keyPressed = F4;
            select;
                when OL_FLD = 'OL_PROT';
                    pos_prot = *on;
                    promptField('protocol' : OL_PROT : rtnShort : rtnLong);
                    OL_PROT  = rtnShort;
                    protocol = rtnLong;
                when OL_FLD = 'OL_SRVR';
                    pos_srvr = *on;
                    promptField('server' : OL_SRVR : rtnShort : rtnLong);
                    OL_SRVR  = rtnShort;
                    OL_SRVRH = rtnLong;
                    server   = rtnLong;
                when OL_FLD = 'OL_PORT';
                    pos_port = *on;
                    promptField('port' : OL_PORT : rtnShort : rtnLong);
                    OL_PORT  = rtnShort;
                    port     = %int(rtnLong);
                when OL_FLD = 'OL_MODL';
                    pos_modl = *on;
                    promptField('model' : OL_MODL : rtnShort : rtnLong);
                    OL_MODL  = rtnShort;
                    OL_MODLH = rtnLong;
                    model    = rtnLong;
            endsl;

        elseif keyPressed = F6;
            // Sync hidden fields before saving
            if chg_srvr;
                OL_SRVRH = OL_SRVR;
            endif;
            if chg_modl;
                OL_MODLH = OL_MODL;
            endif;
            protocol = OL_PROT;
            server   = OL_SRVRH;
            model    = OL_MODLH;
            monitor;
                port = %int(OL_PORT);
            on-error;
                SendProgramMessage('Port number is not valid');
                pos_port = *on;
                iter;
            endmon;
            setMyDefaults();
            SendProgramMessage('User defaults have been updated.');

        elseif keyPressed = ENTER;
            done = *on;
            if chg_srvr;
                OL_SRVRH = OL_SRVR;
            endif;
            if chg_modl;
                OL_MODLH = OL_MODL;
            endif;
            protocol = OL_PROT;
            server   = OL_SRVRH;
            model    = OL_MODLH;
            monitor;
                port = %int(OL_PORT);
                setForJob();
            on-error;
                SendProgramMessage('Port number is not valid');
                pos_port = *on;
                done = *off;
            endmon;

        endif;

    enddo;

    return;
end-proc editOllamaConfig;



//------------------------------------------------------------------------------
// editOAIConfig
// Config sub-screen for the openai_compatible backend.
// API key is masked as '********' if a value is already configured.
// Leaving it as '********' (or blank) preserves the existing key.
//------------------------------------------------------------------------------
dcl-proc editOAIConfig;

    dcl-s done        ind;
    dcl-s rtnShort    varchar(227);
    dcl-s rtnLong     varchar(1000);
    dcl-s keyMasked   ind;

    OA_PROT  = protocol;
    OA_SRVR  = server;
    OA_SRVRH = server;
    OA_PORT  = %char(port);
    OA_MODL  = model;
    OA_MODLH = model;
    OA_PATH  = basepath;

    // Mask the API key on the display field if one is configured
    if %len(%trim(apikey)) > 0;
        OA_KEY   = '********';
        OA_KEYH  = apikey;
        keyMasked = *on;
    else;
        OA_KEY   = '';
        OA_KEYH  = '';
        keyMasked = *off;
    endif;

    dou done;

        write MSGSFLC;
        exfmt OAICFG;
        ClearProgramMessages(2);
        clear pos_prot;
        clear pos_srvr;
        clear pos_port;
        clear pos_modl;
        clear pos_akey;
        clear pos_path;

        if keyPressed = F12 or keyPressed = F3;
            keyPressed = F12;
            done = *on;

        elseif keyPressed = F4;
            select;
                when OA_FLD = 'OA_PROT';
                    pos_prot = *on;
                    promptField('protocol' : OA_PROT : rtnShort : rtnLong);
                    OA_PROT  = rtnShort;
                    protocol = rtnLong;
                when OA_FLD = 'OA_SRVR';
                    pos_srvr = *on;
                    promptField('server' : OA_SRVR : rtnShort : rtnLong);
                    OA_SRVR  = rtnShort;
                    OA_SRVRH = rtnLong;
                    server   = rtnLong;
                when OA_FLD = 'OA_PORT';
                    pos_port = *on;
                    promptField('port' : OA_PORT : rtnShort : rtnLong);
                    OA_PORT  = rtnShort;
                    port     = %int(rtnLong);
                when OA_FLD = 'OA_MODL';
                    pos_modl = *on;
                    promptField('model' : OA_MODL : rtnShort : rtnLong);
                    OA_MODL  = rtnShort;
                    OA_MODLH = rtnLong;
                    model    = rtnLong;
                // No F4 prompt for OA_KEY or OA_PATH — free-entry only
            endsl;

        elseif keyPressed = F6;
            if chg_srvr;
                OA_SRVRH = OA_SRVR;
            endif;
            if chg_modl;
                OA_MODLH = OA_MODL;
            endif;
            protocol = OA_PROT;
            server   = OA_SRVRH;
            model    = OA_MODLH;
            basepath = OA_PATH;
            // If user left the mask in place, restore the real key from hidden field.
            // If user typed something new (or cleared it), use OA_KEY directly.
            if %trim(OA_KEY) = '********';
                apikey = OA_KEYH;
            else;
                apikey  = %trim(OA_KEY);
                OA_KEYH = apikey;
            endif;
            monitor;
                port = %int(OA_PORT);
            on-error;
                SendProgramMessage('Port number is not valid');
                pos_port = *on;
                iter;
            endmon;
            setMyDefaults();
            SendProgramMessage('User defaults have been updated.');

        elseif keyPressed = ENTER;
            done = *on;
            if chg_srvr;
                OA_SRVRH = OA_SRVR;
            endif;
            if chg_modl;
                OA_MODLH = OA_MODL;
            endif;
            protocol = OA_PROT;
            server   = OA_SRVRH;
            model    = OA_MODLH;
            basepath = OA_PATH;
            // If user left the mask in place, restore the real key from hidden field.
            // If user typed something new (or cleared it), use OA_KEY directly.
            if %trim(OA_KEY) = '********';
                apikey = OA_KEYH;
            else;
                apikey  = %trim(OA_KEY);
                OA_KEYH = apikey;
            endif;
            monitor;
                port = %int(OA_PORT);
                setForJob();
            on-error;
                SendProgramMessage('Port number is not valid');
                pos_port = *on;
                done = *off;
            endmon;

        endif;

    enddo;

    return;
end-proc editOAIConfig;



//------------------------------------------------------------------------------
// promptField
// Displays a scrollable subfile of valid values for a given field.
// The 'backend' field is populated from a hardcoded list.
// Protocol/server/port/model pull from the ollama config tables.
// API key and base path have no prompt (free-entry only).
//------------------------------------------------------------------------------
dcl-proc promptField;
    dcl-pi *n;
        in_field    char(10) const;
        in_curVal   varchar(227) const;
        out_short   varchar(227);
        out_long    varchar(1000);
    end-pi;

    dcl-s done ind;
    dcl-s cursorsDeclared ind static;
    dcl-ds promptValues   qualified dim(*auto : 1000);
        text   varchar(1000);
    end-ds;
    if not cursorsDeclared;
        exsr declareCursors;
        cursorsDeclared = *on;
    endif;

    // Seed output with the current value
    if in_field = 'backend';
        out_short = in_curVal;
        out_long  = backend;
    elseif in_field = 'protocol';
        out_short = in_curVal;
        out_long  = protocol;
    elseif in_field = 'port';
        out_short = in_curVal;
        out_long  = %char(port);
    elseif in_field = 'server';
        out_short = in_curVal;
        out_long  = server;
    elseif in_field = 'model';
        out_short = in_curVal;
        out_long  = model;
    endif;

    P_FIELD = in_field;
    exsr loadPromptValues;
    exsr clearSubfile;
    exsr loadSubfile;

    dou done;
        write PROMPTKEYS;
        exfmt PROMPTCTL;

        if keyPressed = F3;
            keyPressed = F12;
            done = *on;

        elseif keyPressed = F12;
            done = *on;

        elseif keyPressed = ENTER;
            dou %eof(LLMDSPF);
                readc PROMPTSFL;
                if %eof(LLMDSPF) or P_SELECT <> '1';
                    iter;
                endif;

                done      = *on;
                out_short = P_TEXT;
                out_long  = P_VALUE;
                leave;

            enddo;
        endif;

    enddo;

    return;

    //--------------------------------------------------------------------------
    begsr loadPromptValues;

        if in_field = 'backend';
            // Fetch hardcoded backend names via a declared cursor so that
            // the dim(*auto) array is properly allocated by SQL FETCH.
            Exec SQL OPEN llmrpg_backend;
            Exec SQL FETCH llmrpg_backend
                     FOR 1000 ROWS
                     INTO :promptValues;
            Exec SQL CLOSE llmrpg_backend;

        elseif in_field = 'protocol';
            Exec SQL OPEN llmrpg_protocol;
            Exec SQL FETCH llmrpg_protocol
                     FOR 1000 ROWS
                     INTO :promptValues;
            Exec SQL CLOSE llmrpg_protocol;

        elseif in_field = 'port';
            Exec SQL OPEN llmrpg_port;
            Exec SQL FETCH llmrpg_port
                     FOR 1000 ROWS
                     INTO :promptValues;
            Exec SQL CLOSE llmrpg_port;

        elseif in_field = 'server';
            Exec SQL OPEN llmrpg_server;
            Exec SQL FETCH llmrpg_server
                     FOR 1000 ROWS
                     INTO :promptValues;
            Exec SQL CLOSE llmrpg_server;

        elseif in_field = 'model';
            Exec SQL OPEN llmrpg_model;
            Exec SQL FETCH llmrpg_model
                     FOR 1000 ROWS
                     INTO :promptValues;
            Exec SQL CLOSE llmrpg_model;

        endif;

    endsr;

    //--------------------------------------------------------------------------
    begsr clearSubfile;
        sfl_dsp    = *off;
        sfl_dspCtl = *off;
        rrn1       = 0;
        write PROMPTCTL;
        sfl_dsp    = *on;
        sfl_dspCtl = *on;
    endsr;

    //--------------------------------------------------------------------------
    begsr loadSubfile;
        // Cap at SFLSIZ(1000) - 1 to avoid subfile overflow
        for rrn1 = 1 to %min(%elem(promptValues) : 999);
            clear PROMPTSFL;
            P_VALUE = promptValues(rrn1).text;
            if %len(%trim(P_VALUE)) > %len(P_TEXT) and %len(P_TEXT) >= 4;
                P_TEXT = %subst(%trim(P_VALUE) : 1 : %len(P_TEXT) - 3) + '...';
            else;
                P_TEXT = %trim(P_VALUE);
            endif;
            write PROMPTSFL;
        endfor;
        sfl_end  = (%elem(promptValues) <= 999);
        P_RCDNBR = 1;
    endsr;

    //--------------------------------------------------------------------------
    begsr declareCursors;
        Exec SQL
        DECLARE llmrpg_backend CURSOR FOR
            SELECT CAST('ollama' AS VARCHAR(1000)) FROM SYSIBM.SYSDUMMY1
            UNION ALL
            SELECT CAST('openai_compatible' AS VARCHAR(1000)) FROM SYSIBM.SYSDUMMY1;

        Exec SQL
        DECLARE llmrpg_protocol CURSOR FOR
            SELECT ollama_protocol
            FROM ollama_config_protocol;

        Exec SQL
        DECLARE llmrpg_port CURSOR FOR
            SELECT CHAR(ollama_port)
            FROM ollama_config_port;

        Exec SQL
        DECLARE llmrpg_server CURSOR FOR
            SELECT ollama_server
            FROM ollama_config_server;

        Exec SQL
        DECLARE llmrpg_model CURSOR FOR
            SELECT ollama_model
            FROM ollama_config_model;
    endsr;

end-proc promptField;



//------------------------------------------------------------------------------
// callLLM
// Dispatches to the correct backend's generate function.
//------------------------------------------------------------------------------
dcl-proc callLLM;
    dcl-pi *n  varchar(1000);
        in_prompt  varchar(500) const;
    end-pi;

    dcl-s llmResponse  SQLTYPE(CLOB : 16000000);
    dcl-s prompt       varchar(1000);
    dcl-s rtnVal       varchar(1000);

    // Sanity-check: re-fetch current settings so the SQL globals are current
    dcl-s l_protocol  varchar(16);
    dcl-s l_server    varchar(1000);
    dcl-s l_port      int(10);
    dcl-s l_model     varchar(1000);

    if backend = 'openai_compatible';

        Exec SQL SET :l_protocol = (
            VALUES dbsdk_v1.openai_compatible_getprotocol() );
        Exec SQL SET :l_server = (
            VALUES dbsdk_v1.openai_compatible_getserver() );
        Exec SQL SET :l_port = (
            VALUES dbsdk_v1.openai_compatible_getport() );
        Exec SQL SET :l_model = (
            VALUES dbsdk_v1.openai_compatible_getmodel() );

        // openai_compatible_generate takes a plain text prompt.
        // Pass options=>'{}', api_key_=>NULL, base_url=>NULL so the function
        // uses the job-level SQL globals set by setForJob().
        Exec SQL
            SET :llmResponse = (
                VALUES dbsdk_v1.openai_compatible_chat_generate(
                    prompt   => TRIM(:in_prompt),
                    options  => '{}' )
            );

    else;
        // Default: ollama

        Exec SQL SET :l_protocol = (
            VALUES dbsdk_v1.ollama_getprotocol() );
        Exec SQL SET :l_server = (
            VALUES dbsdk_v1.ollama_getserver() );
        Exec SQL SET :l_port = (
            VALUES dbsdk_v1.ollama_getport() );
        Exec SQL SET :l_model = (
            VALUES dbsdk_v1.ollama_getmodel() );

        // ollama_generate expects a JSON message object
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
        SendProgramMessage('SQL Error: ' + %char(sqlcode));
    endif;

    rtnVal = llmResponse_DATA;
    return rtnVal;
end-proc callLLM;



//------------------------------------------------------------------------------
// SendProgramMessage
// Sends an informational message to the display (QMHSNDPM).
//------------------------------------------------------------------------------
dcl-proc  SendProgramMessage;
    dcl-pi  *n;
        in_message  varchar(80) const;
    end-pi;

    dcl-pr  SendMessage  extpgm('QMHSNDPM');
        msgId            char(7)  const;
        msgFile          char(20) const;
        msgData          char(80) const;
        msgLength        int(10)  const;
        msgType          char(10) const;
        stackEntry       char(10) const;
        stackCounter     int(10)  const;
        msgKey           char(4);
        errorDs          likeds(errorDs);
    end-pr;

    dcl-ds  errorDs;
        bytesProvided    int(10) inz(16);
        bytesAvailable   int(10);
        exceptionId      char(7);
    end-ds;
    dcl-s msgKey   char(4);

    SendMessage( 'CPF9898'
               : 'QCPFMSG   QSYS'
               : in_message
               : %len(in_message)
               : '*INFO'
               : pgmName
               : 0
               : msgKey
               : errorDS
               );

end-proc  SendProgramMessage;



//------------------------------------------------------------------------------
// ClearProgramMessages
// Clears informational messages from the display (QMHRMVPM).
//------------------------------------------------------------------------------
dcl-proc  ClearProgramMessages;
    dcl-pi *n;
        in_stackEntry   int(10) const;
    end-pi;

    dcl-pr  RemoveMessage  extpgm('QMHRMVPM');
        stackEntry       char(10) const;
        stackCount       int(10)  const;
        msgKey           char(4)  const;
        toRemove         char(10) const;
        errorDs          likeds(errorDs);
    end-pr;

    dcl-ds  errorDs;
        bytesProvided    int(10) inz(16);
        bytesAvailable   int(10);
        exceptionId      char(7);
    end-ds;
    dcl-s msgKey   char(4);

    RemoveMessage( '*'
                 : in_stackEntry
                 : ' '
                 : '*ALL'
                 : errorDS
                 );

    return;
end-proc  ClearProgramMessages;
