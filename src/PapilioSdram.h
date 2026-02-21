#pragma once

/**
 * @file PapilioSdram.h
 * @brief Wishbone SDRAM controller API for Papilio Retrocade
 *
 * Provides read/write access to the external W9825G6KH-6 SDRAM (32 MB)
 * via the Wishbone extended tier at a configurable base address.
 *
 * The SDRAM is accessed through a paged window:
 *   - Each page is 4 KB (2048 × 16-bit words)
 *   - 8192 pages cover the full 32 MB
 *   - setPage() selects the active page; the window maps to readWord()/writeWord()
 *
 * Hardware memory verification runs autonomously at SDRAM clock speed (~100 MHz),
 * testing the full address range without stalling the SPI bus.
 *
 * @example
 *   PapilioSdram sdram(0x8000);
 *   sdram.begin();
 *   sdram.writeWord(0x000000, 0xABCD);
 *   uint16_t v = sdram.readWord(0x000000); // returns 0xABCD
 *   sdram.verify(SDRAM_PAT_WALKING, 0, 1024);
 *   while (sdram.verifyRunning()) delay(1);
 *   bool ok = sdram.verifyPassed();
 */

#include <Arduino.h>
#include <WishboneSPI.h>

// ============================================================
// Register offsets (relative to base address)
// ============================================================
#define SDRAM_REG_CSR         0x0000  ///< [0]=init_done
#define SDRAM_REG_PAGE        0x0004  ///< [12:0] page number
#define SDRAM_REG_DIR_ADDR    0x0008  ///< [23:0] direct SDRAM word address
#define SDRAM_REG_DIR_DATA    0x000C  ///< [15:0] direct data (triggers SDRAM R/W)
#define SDRAM_REG_VFY_CTRL    0x0010  ///< [1:0]=pattern, [7]=start; read: [9]=pass, [8]=done
#define SDRAM_REG_VFY_START   0x0014  ///< [23:0] verify region start (word addr)
#define SDRAM_REG_VFY_SIZE    0x0018  ///< [23:0] verify region size (words)
#define SDRAM_REG_VFY_FAIL    0x001C  ///< [23:0] first fail word address (RO)

// CSR bits
#define SDRAM_CSR_INIT_DONE   (1 << 0)

// Verify control bits
#define SDRAM_VFY_START_BIT   (1 << 7)
#define SDRAM_VFY_DONE_BIT    (1 << 8)
#define SDRAM_VFY_PASS_BIT    (1 << 9)

// ============================================================
// Memory parameters
// ============================================================
#define SDRAM_TOTAL_BYTES     (32UL * 1024 * 1024)  ///< 32 MB
#define SDRAM_TOTAL_WORDS     (SDRAM_TOTAL_BYTES / 2) ///< 16 M × 16-bit words
#define SDRAM_PAGE_WORDS      2048U   ///< words per page
#define SDRAM_PAGE_BYTES      4096U   ///< bytes per page
#define SDRAM_NUM_PAGES       8192U   ///< total pages

// Paged window offset within the extended tier slot
#define SDRAM_WINDOW_OFFSET   0x0100  ///< local offset of paged window start

/** Verification patterns */
enum SdramPattern {
    SDRAM_PAT_WALKING  = 0,  ///< Walking ones
    SDRAM_PAT_ADDR     = 1,  ///< Address as data
    SDRAM_PAT_RANDOM   = 2,  ///< Pseudo-random (LFSR)
    SDRAM_PAT_FILL     = 3   ///< Fill with 0xA5A5
};

// ============================================================
// PapilioSdram class
// ============================================================

class PapilioSdram {
public:
    /**
     * @param baseAddress Extended-tier base address (default 0x8000 matches top.v)
     */
    explicit PapilioSdram(uint16_t baseAddress = 0x8000);

    /**
     * @brief Initialize and verify SDRAM controller is ready.
     * Waits up to timeoutMs for init_done to assert.
     * @return true if SDRAM initialized successfully
     */
    bool begin(uint32_t timeoutMs = 1000);

    /** @return true if SDRAM controller has completed initialization */
    bool isReady();

    // ----------------------------------------------------------
    // Direct access (random access across full 32 MB)
    // Two Wishbone transactions per operation: write address, then read/write data.
    // ----------------------------------------------------------

    /**
     * @brief Read a 16-bit word from any SDRAM address.
     * @param wordAddr 24-bit word address (0 – 16,777,215)
     */
    uint16_t readWord(uint32_t wordAddr);

    /**
     * @brief Write a 16-bit word to any SDRAM address.
     * @param wordAddr 24-bit word address
     * @param data     16-bit value to write
     */
    void writeWord(uint32_t wordAddr, uint16_t data);

    // ----------------------------------------------------------
    // Paged block access (efficient for sequential access)
    // Automatically switches pages as needed.
    // ----------------------------------------------------------

    /**
     * @brief Write a block of 16-bit words starting at wordAddr.
     * Handles page boundaries automatically.
     */
    void writeBlock(uint32_t wordAddr, const uint16_t* data, uint32_t count);

    /**
     * @brief Read a block of 16-bit words starting at wordAddr.
     * Handles page boundaries automatically.
     */
    void readBlock(uint32_t wordAddr, uint16_t* data, uint32_t count);

    /**
     * @brief Fill a region of SDRAM with a constant value.
     */
    void fill(uint32_t wordAddr, uint32_t count, uint16_t value);

    // ----------------------------------------------------------
    // Hardware memory verification
    // ----------------------------------------------------------

    /**
     * @brief Start hardware memory verification (non-blocking).
     * The verification engine runs at SDRAM clock speed.
     * @param pattern Which test pattern to use
     * @param startWordAddr Start of region to test
     * @param wordCount Number of words to test (default = full 32 MB)
     */
    void startVerify(SdramPattern pattern = SDRAM_PAT_WALKING,
                     uint32_t startWordAddr = 0,
                     uint32_t wordCount = SDRAM_TOTAL_WORDS);

    /** @return true while hardware verification is running */
    bool verifyRunning();

    /** @return true if last verification completed with no errors */
    bool verifyPassed();

    /** @return word address of first failure (only valid if !verifyPassed()) */
    uint32_t verifyFailAddress();

    /**
     * @brief Blocking verify — starts, waits for completion, returns pass/fail.
     */
    bool verify(SdramPattern pattern = SDRAM_PAT_WALKING,
                uint32_t startWordAddr = 0,
                uint32_t wordCount = SDRAM_TOTAL_WORDS);

    // ----------------------------------------------------------
    // Utility
    // ----------------------------------------------------------
    uint32_t getMemorySizeBytes() { return SDRAM_TOTAL_BYTES; }
    uint16_t getBaseAddress()     { return _base; }

private:
    uint16_t _base;

    void     _setPage(uint16_t page);
    void     _writeDirAddr(uint32_t wordAddr);
    uint16_t _readDirData();
    void     _writeDirData(uint16_t data);

    uint16_t _currentPage;

    uint32_t _readReg32(uint16_t offset);
    void     _writeReg32(uint16_t offset, uint32_t value);
};
