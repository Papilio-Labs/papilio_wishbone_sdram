#pragma once

#ifdef ENABLE_PAPILIO_OS

#include <PapilioOS.h>
#include "PapilioSdram.h"

/**
 * @file PapilioSdramOS.h
 * @brief papilio_os CLI plugin for SDRAM controller
 *
 * Commands:
 *   sdram help            - Show all commands
 *   sdram status          - Show controller state and init status
 *   sdram read <addr>     - Read 16-bit word at SDRAM word address
 *   sdram write <addr> <data>  - Write 16-bit word
 *   sdram fill <addr> <count> <value>  - Fill region
 *   sdram dump <addr> <count>  - Hex dump
 *   sdram verify [walking|addr|random|fill] [start] [size]  - Run hw verify
 *   sdram tutorial        - Interactive walkthrough
 */
class PapilioSdramOS {
public:
    explicit PapilioSdramOS(PapilioSdram* device);

private:
    PapilioSdram* _device;
    static PapilioSdramOS* _instance;

    void registerCommands();

    static void handleHelp   (int argc, char** argv);
    static void handleStatus (int argc, char** argv);
    static void handleRead   (int argc, char** argv);
    static void handleWrite  (int argc, char** argv);
    static void handleFill   (int argc, char** argv);
    static void handleDump   (int argc, char** argv);
    static void handleVerify (int argc, char** argv);
    static void handleTutorial(int argc, char** argv);

    static const char* patternName(SdramPattern p);
    static SdramPattern parsePattern(const char* s);
};

#endif // ENABLE_PAPILIO_OS
