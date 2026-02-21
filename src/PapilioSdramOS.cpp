#include "PapilioSdramOS.h"

#ifdef ENABLE_PAPILIO_OS

PapilioSdramOS* PapilioSdramOS::_instance = nullptr;

PapilioSdramOS::PapilioSdramOS(PapilioSdram* device) : _device(device) {
    _instance = this;
    registerCommands();
}

void PapilioSdramOS::registerCommands() {
    PapilioOS.registerCommand("sdram", "help",     "Show all sdram commands",            handleHelp);
    PapilioOS.registerCommand("sdram", "status",   "Show SDRAM controller status",       handleStatus);
    PapilioOS.registerCommand("sdram", "read",     "Read 16-bit word:  read <addr>",     handleRead);
    PapilioOS.registerCommand("sdram", "write",    "Write 16-bit word: write <addr> <data>", handleWrite);
    PapilioOS.registerCommand("sdram", "fill",     "Fill region:       fill <addr> <count> <value>", handleFill);
    PapilioOS.registerCommand("sdram", "dump",     "Hex dump:          dump <addr> [count]", handleDump);
    PapilioOS.registerCommand("sdram", "verify",   "Hardware verify:   verify [walking|addr|random|fill] [start] [size]", handleVerify);
    PapilioOS.registerCommand("sdram", "tutorial", "Interactive step-by-step walkthrough", handleTutorial);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleHelp(int argc, char** argv) {
    PapilioOS.println("sdram commands:");
    PapilioOS.println("  status                        - controller state");
    PapilioOS.println("  read <addr>                   - read word at hex address");
    PapilioOS.println("  write <addr> <data>           - write word");
    PapilioOS.println("  fill <addr> <count> <value>   - fill region");
    PapilioOS.println("  dump <addr> [count=16]        - hex dump");
    PapilioOS.println("  verify [walking|addr|random|fill] [start=0] [size=all]");
    PapilioOS.println("  tutorial                      - guided walkthrough");
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleStatus(int argc, char** argv) {
    if (!_instance) return;
    PapilioSdram* d = _instance->_device;
    PapilioOS.print("SDRAM status: ");
    if (d->isReady()) {
        PapilioOS.println("READY (init_done)");
    } else {
        PapilioOS.println("NOT READY (waiting for init_done)");
    }
    PapilioOS.printf("  Memory size:   %lu MB\r\n", d->getMemorySizeBytes() / (1024*1024));
    PapilioOS.printf("  Base address:  0x%04X\r\n", d->getBaseAddress());
    PapilioOS.printf("  Page size:     %u words (%u bytes)\r\n", SDRAM_PAGE_WORDS, SDRAM_PAGE_BYTES);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleRead(int argc, char** argv) {
    if (!_instance || argc < 2) {
        PapilioOS.println("Usage: sdram read <addr>");
        return;
    }
    uint32_t addr = strtoul(argv[1], nullptr, 16);
    uint16_t data = _instance->_device->readWord(addr);
    PapilioOS.printf("  [0x%06lX] = 0x%04X (%u)\r\n", addr, data, data);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleWrite(int argc, char** argv) {
    if (!_instance || argc < 3) {
        PapilioOS.println("Usage: sdram write <addr> <data>");
        return;
    }
    uint32_t addr = strtoul(argv[1], nullptr, 16);
    uint16_t data = (uint16_t)strtoul(argv[2], nullptr, 16);
    _instance->_device->writeWord(addr, data);
    PapilioOS.printf("  Wrote 0x%04X to [0x%06lX]\r\n", data, addr);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleFill(int argc, char** argv) {
    if (!_instance || argc < 4) {
        PapilioOS.println("Usage: sdram fill <addr> <count> <value>");
        return;
    }
    uint32_t addr  = strtoul(argv[1], nullptr, 16);
    uint32_t count = strtoul(argv[2], nullptr, 0);
    uint16_t val   = (uint16_t)strtoul(argv[3], nullptr, 16);
    _instance->_device->fill(addr, count, val);
    PapilioOS.printf("  Filled %lu words at 0x%06lX with 0x%04X\r\n", count, addr, val);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleDump(int argc, char** argv) {
    if (!_instance || argc < 2) {
        PapilioOS.println("Usage: sdram dump <addr> [count=16]");
        return;
    }
    uint32_t addr  = strtoul(argv[1], nullptr, 16);
    uint32_t count = (argc >= 3) ? strtoul(argv[2], nullptr, 0) : 16;
    if (count > 256) count = 256;

    PapilioSdram* d = _instance->_device;
    for (uint32_t i = 0; i < count; i++) {
        if ((i % 8) == 0) PapilioOS.printf("  %06lX: ", addr + i);
        PapilioOS.printf("%04X ", d->readWord(addr + i));
        if ((i % 8) == 7) PapilioOS.println("");
    }
    if (count % 8 != 0) PapilioOS.println("");
}

// ----------------------------------------------------------------
const char* PapilioSdramOS::patternName(SdramPattern p) {
    switch (p) {
        case SDRAM_PAT_WALKING: return "walking-ones";
        case SDRAM_PAT_ADDR:    return "address-as-data";
        case SDRAM_PAT_RANDOM:  return "pseudo-random";
        case SDRAM_PAT_FILL:    return "fill(0xA5A5)";
        default:                return "unknown";
    }
}

SdramPattern PapilioSdramOS::parsePattern(const char* s) {
    if (!s) return SDRAM_PAT_WALKING;
    if (strncmp(s, "addr",   4) == 0) return SDRAM_PAT_ADDR;
    if (strncmp(s, "random", 6) == 0) return SDRAM_PAT_RANDOM;
    if (strncmp(s, "fill",   4) == 0) return SDRAM_PAT_FILL;
    return SDRAM_PAT_WALKING;
}

void PapilioSdramOS::handleVerify(int argc, char** argv) {
    if (!_instance) return;
    PapilioSdram* d   = _instance->_device;
    SdramPattern  pat = (argc >= 2) ? parsePattern(argv[1]) : SDRAM_PAT_WALKING;
    uint32_t      start = (argc >= 3) ? strtoul(argv[2], nullptr, 16) : 0;
    uint32_t      size  = (argc >= 4) ? strtoul(argv[3], nullptr, 0) : SDRAM_TOTAL_WORDS;

    PapilioOS.printf("  Starting hardware verify: %s from 0x%06lX, %lu words...\r\n",
                     patternName(pat), start, size);
    d->startVerify(pat, start, size);

    uint32_t t0 = millis();
    while (d->verifyRunning()) {
        delay(100);
        PapilioOS.print(".");
    }
    uint32_t elapsed = millis() - t0;
    PapilioOS.println("");
    PapilioOS.printf("  Done in %lu ms. Result: %s\r\n", elapsed,
                     d->verifyPassed() ? "PASS" : "FAIL");
    if (!d->verifyPassed()) {
        PapilioOS.printf("  First failure at word address: 0x%06lX\r\n", d->verifyFailAddress());
    }
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleTutorial(int argc, char** argv) {
    if (!_instance) return;
    PapilioSdram* d = _instance->_device;

    PapilioOS.println("\r\n=== SDRAM Tutorial ===");
    PapilioOS.println("This tutorial walks through using the external SDRAM on your Papilio Retrocade.");
    PapilioOS.println("Type 'exit' at any prompt to quit.\r\n");

    // Step 1: Check status
    PapilioOS.println("Step 1: Check that the SDRAM controller has initialized.");
    PapilioOS.println("  Try: sdram status");
    PapilioOS.println("  The SDRAM needs ~200µs to initialize after power-up.");
    if (!d->isReady()) {
        PapilioOS.println("  [WARNING] SDRAM is not yet ready. Check FPGA bitstream and hardware.");
    } else {
        PapilioOS.println("  [OK] SDRAM is ready.");
    }

    // Step 2: Write and read back
    PapilioOS.println("\r\nStep 2: Write and read a word.");
    PapilioOS.println("  Writing 0xBEEF to address 0x000010...");
    d->writeWord(0x000010, 0xBEEF);
    uint16_t v = d->readWord(0x000010);
    PapilioOS.printf("  Read back: 0x%04X  %s\r\n", v,
                     (v == 0xBEEF) ? "[PASS]" : "[FAIL - check FPGA]");

    // Step 3: Memory verification
    PapilioOS.println("\r\nStep 3: Run hardware memory verification (small region).");
    PapilioOS.println("  Testing first 1024 words with walking-ones pattern...");
    bool ok = d->verify(SDRAM_PAT_WALKING, 0, 1024);
    PapilioOS.printf("  Result: %s\r\n", ok ? "PASS" : "FAIL");

    // Step 4: Full verify
    PapilioOS.println("\r\nStep 4: Run a full 32 MB verify (this takes ~1 second).");
    PapilioOS.println("  Try: sdram verify addr");
    PapilioOS.println("  While running, the HDMI display will continue unaffected.");

    PapilioOS.println("\r\n=== Tutorial complete ===");
    PapilioOS.println("Commands to explore further:");
    PapilioOS.println("  sdram dump 0 32         - Inspect first 32 words");
    PapilioOS.println("  sdram fill 0 1000 DEAD  - Fill region");
    PapilioOS.println("  sdram verify random     - Pseudo-random pattern test");
}

#endif // ENABLE_PAPILIO_OS
