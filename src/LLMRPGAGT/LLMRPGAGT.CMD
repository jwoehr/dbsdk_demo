/*===========================================================================*/
/* LLMRPGAGT - Command definition for the ReAct LLM agent                  */
/*                                                                           */
/* Wraps CALL PGM(LLMRPGAGT) with named, prompted parameters.               */
/* Two required parameters, three optional.                                  */
/* CPP is specified on CRTCMD PGM() - not inside this source.               */
/*===========================================================================*/
             CMD        PROMPT('Run LLMRPGAGT ReAct Agent')

/*---------------------------------------------------------------------------*/
/* Required parameters                                                       */
/*---------------------------------------------------------------------------*/
             PARM       KWD(PROVIDER) TYPE(*CHAR) LEN(20) MIN(1) +
                          CHOICE('ollama, openai_compatible') +
                          PROMPT('LLM backend provider name')

             PARM       KWD(LISTEN) TYPE(*CHAR) LEN(100) MIN(1) +
                          PROMPT('Interface and port  iface:port')

/*---------------------------------------------------------------------------*/
/* Optional parameters                                                       */
/*---------------------------------------------------------------------------*/
             PARM       KWD(MCPURL) TYPE(*CHAR) LEN(1000) MIN(0) +
                          DFT(' ') +
                          PROMPT('MCP server URL')

             PARM       KWD(SKILLS) TYPE(*CHAR) LEN(1000) MIN(0) +
                          DFT(' ') +
                          PROMPT('IFS path to skills file')

             PARM       KWD(LOGPATH) TYPE(*CHAR) LEN(1000) MIN(0) +
                          DFT(' ') +
                          PROMPT('IFS path for log file')
