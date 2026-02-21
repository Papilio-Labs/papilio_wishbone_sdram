#include "PapilioSdramOS.h"

#ifdef ENABLE_PAPILIO_OS

PapilioSdramOS* PapilioSdramOS::_instance = nullptr;

PapilioSdramOS::PapilioSdramOS(PapilioSdram* device) : _device(device) {
    _instance = this;
    registerCommands();
}

void PapilioSdramOS::registerCommands() {
    PapilioOS.registerCommand("sdram", "help",     handleHelp,     "Show all sdram commands");
    PapilioOS.registerCommand("sdram", "status",   handleStatus,   "Show SDRAM controller status");
    PapilioOS.registerCommand("sdram", "read",     handleRead,     "Read 16-bit word:  read <addr>");
    PapilioOS.registerCommand("sdram", "write",    handleWrite,    "Write 16-bit word: write <addr> <data>");
    PapilioOS.registerCommand("sdram", "fill",     handleFill,     "Fill region:       fill <addr> <count> <value>");
    PapilioOS.registerCommand("sdram", "dump",     handleDump,     "Hex dump:          dump <addr> [count]");
    PapilioOS.registerCommand("sdram", "verify",   handleVerify,   "Hardware verify:   verify [walking|addr|random|fill] [start] [size]");
    PapilioOS.registerCommand("sdram", "tutorial", handleTutorial, "Interactive step-by-step walkthrough");
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleHelp(int argc, char** argv) {
    Serial.println("sdram commands:");
    Serial.println("  status                        - controller state");
    Serial.println("  read <addr>                   - read word at hex address");
    Serial.println("  write <addr> <data>           - write word");
    Serial.println("  fill <addr> <count> <value>   - fill region");
    Serial.println("  dump <addr> [count=16]        - hex dump");
    Serial.println("  verify [walking|addr|random|fill] [start=0] [size=all]");
    Serial.println("  tutorial                      - guided walkthrough");
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleStatus(int argc, char** argv) {
    if (!_instance) return;
    PapilioSdram* d = _instance->_device;
    Serial.print("SDRAM status: ");
    if (d->isReady()) {
        Serial.println("READY (init_done)");
    } else {
        Serial.println("NOT READY (waiting for init_done)");
    }
    Serial.printf("  Memory size:   %lu MB\r\n", d->getMemorySizeBytes() / (1024*1024));
    Serial.printf("  Base address:  0x%04X\r\n", d->getBaseAddress());
    Serial.printf("  Page size:     %u words (%u bytes)\r\n", SDRAM_PAGE_WORDS, SDRAM_PAGE_BYTES);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleRead(int argc, char** argv) {
    if (!_instance || argc < 2) {
        Serial.println("Usage: sdram read <addr>");
        return;
    }
    uint32_t addr = strtoul(argv[1], nullptr, 16);
    uint16_t data = _instance->_device->readWord(addr);
    Serial.printf("  [0x%06lX] = 0x%04X (%u)\r\n", addr, data, data);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleWrite(int argc, char** argv) {
    if (!_instance || argc < 3) {
        Serial.println("Usage: sdram write <addr> <data>");
        return;
    }
    uint32_t addr = strtoul(argv[1], nullptr, 16);
    uint16_t data = (uint16_t)strtoul(argv[2], nullptr, 16);
    _instance->_device->writeWord(addr, data);
    Serial.printf("  Wrote 0x%04X to [0x%06lX]\r\n", data, addr);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleFill(int argc, char** argv) {
    if (!_instance || argc < 4) {
        Serial.println("Usage: sdram fill <addr> <count> <value>");
        return;
    }
    uint32_t addr  = strtoul(argv[1], nullptr, 16);
    uint32_t count = strtoul(argv[2], nullptr, 0);
    uint16_t val   = (uint16_t)strtoul(argv[3], nullptr, 16);
    _instance->_device->fill(addr, count, val);
    Serial.printf("  Filled %lu words at 0x%06lX with 0x%04X\r\n", count, addr, val);
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleDump(int argc, char** argv) {
    if (!_instance || argc < 2) {
        Serial.println("Usage: sdram dump <addr> [count=16]");
        return;
    }
    uint32_t addr  = strtoul(argv[1], nullptr, 16);
    uint32_t count = (argc >= 3) ? strtoul(argv[2], nullptr, 0) : 16;
    if (count > 256) count = 256;

    PapilioSdram* d = _instance->_device;
    for (uint32_t i = 0; i < count; i++) {
        if ((i % 8) == 0) Serial.printf("  %06lX: ", addr + i);
        Serial.printf("%04X ", d->readWord(addr + i));
        if ((i % 8) == 7) Serial.println("");
    }
    if (count % 8 != 0) Serial.println("");
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

    Serial.printf("  Starting hardware verify: %s from 0x%06lX, %lu words...\r\n",
                     patternName(pat), start, size);
    d->startVerify(pat, start, size);

    uint32_t t0 = millis();
    while (d->verifyRunning()) {
        delay(100);
        Serial.print(".");
    }
    uint32_t elapsed = millis() - t0;
    Serial.println("");
    Serial.printf("  Done in %lu ms. Result: %s\r\n", elapsed,
                     d->verifyPassed() ? "PASS" : "FAIL");
    if (!d->verifyPassed()) {
        Serial.printf("  First failure at word address: 0x%06lX\r\n", d->verifyFailAddress());
    }
}

// ----------------------------------------------------------------
void PapilioSdramOS::handleTutorial(int argc, char** argv) {
    if (!_instance) return;
    PapilioSdram* d = _instance->_device;

    Serial.println("\r\n=== SDRAM Tutorial ===");
    Serial.println("This tutorial walks through using the external SDRAM on your Papilio Retrocade.");
    Serial.println("Type 'exit' at any prompt to quit.\r\n");

    // Step 1: Check status
    Serial.println("Step 1: Check that the SDRAM controller has initialized.");
    Serial.println("  Try: sdram status");
    Serial.println("  The SDRAM needs ~200µs to initialize after power-up.");
    if (!d->isReady()) {
        Serial.println("  [WARNING] SDRAM is not yet ready. Check FPGA bitstream and hardware.");
    } else {
        Serial.println("  [OK] SDRAM is ready.");
    }

    // Step 2: Write and read back
    Serial.println("\r\nStep 2: Write and read a word.");
    Serial.println("  Writing 0xBEEF to address 0x000010...");
    d->writeWord(0x000010, 0xBEEF);
    uint16_t v = d->readWord(0x000010);
    Serial.printf("  Read back: 0x%04X  %s\r\n", v,
                     (v == 0xBEEF) ? "[PASS]" : "[FAIL - check FPGA]");

    // Step 3: Memory verification
    Serial.println("\r\nStep 3: Run hardware memory verification (small region).");
    Serial.println("  Testing first 1024 words with walking-ones pattern...");
    bool ok = d->verify(SDRAM_PAT_WALKING, 0, 1024);
    Serial.printf("  Result: %s\r\n", ok ? "PASS" : "FAIL");

    // Step 4: Full verify
    Serial.println("\r\nStep 4: Run a full 32 MB verify (this takes ~1 second).");
    Serial.println("  Try: sdram verify addr");
    Serial.println("  While running, the HDMI display will continue unaffected.");

    Serial.println("\r\n=== Tutorial complete ===");
    Serial.println("Commands to explore further:");
    Serial.println("  sdram dump 0 32         - Inspect first 32 words");
    Serial.println("  sdram fill 0 1000 DEAD  - Fill region");
    Serial.println("  sdram verify random     - Pseudo-random pattern test");
}

#endif // ENABLE_PAPILIO_OS
