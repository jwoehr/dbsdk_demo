/*===========================================================================*/
/* LLMRPGAGT - Command definition for the ReAct LLM agent                  */
/*                                                                           */
/* Wraps CALL PGM(LLMRPGAGT) with named, prompted parameters.               */
/* Two required parameters, four optional.                                   */
/* CPP is specified on CRTCMD PGM() - not inside this source.               */
/*===========================================================================*/
             CMD        PROMPT('Run LLMRPGAGT ReAct Agent')

/*---------------------------------------------------------------------------*/
/* Required parameters                                                       */
/*---------------------------------------------------------------------------*/
             PARM       KWD(PROVIDER) TYPE(*CHAR) LEN(20) MIN(1) +
                           CASE(*MIXED) +
                           CHOICE('ollama, openai_compatible') +
                           PROMPT('LLM backend provider name')

             PARM       KWD(LISTEN) TYPE(*CHAR) LEN(100) MIN(1) +
                           CASE(*MIXED) +
                           PROMPT('Interface:port iface:port')

/*---------------------------------------------------------------------------*/
/* Optional parameters                                                       */
/*---------------------------------------------------------------------------*/
             PARM       KWD(MCPURL) TYPE(*CHAR) LEN(1000) MIN(0) +
                           DFT(' ') +
                           CASE(*MIXED) +
                           PMTCTL(*PMTRQS) +
                           PROMPT('MCP server URL')

             PARM       KWD(MCPAPIKEY) TYPE(*CHAR) LEN(256) MIN(0) +
                           DFT(' ') +
                           CASE(*MIXED) +
                           PMTCTL(*PMTRQS) +
                           PROMPT('MCP server API key/Bearer tkn')

             PARM       KWD(SKILLS) TYPE(*CHAR) LEN(1000) MIN(0) +
                           DFT(' ') +
                           CASE(*MIXED) +
                           PMTCTL(*PMTRQS) +
                           PROMPT('IFS path to skills file')

             PARM       KWD(LOGPATH) TYPE(*CHAR) LEN(1000) MIN(0) +
                           DFT(' ') +
                           CASE(*MIXED) +
                           PMTCTL(*PMTRQS) +
                           PROMPT('IFS path for log file')
