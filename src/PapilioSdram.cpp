#include "PapilioSdram.h"

PapilioSdram::PapilioSdram(uint16_t baseAddress)
    : _base(baseAddress), _currentPage(0xFFFF) {}

// ----------------------------------------------------------------
// Private register helpers
// ----------------------------------------------------------------
uint32_t PapilioSdram::_readReg32(uint16_t offset) {
    return wishboneRead32(_base + offset);
}

void PapilioSdram::_writeReg32(uint16_t offset, uint32_t value) {
    wishboneWrite32(_base + offset, value);
}

void PapilioSdram::_setPage(uint16_t page) {
    if (page != _currentPage) {
        _writeReg32(SDRAM_REG_PAGE, page);
        _currentPage = page;
    }
}

void PapilioSdram::_writeDirAddr(uint32_t wordAddr) {
    _writeReg32(SDRAM_REG_DIR_ADDR, wordAddr & 0x00FFFFFF);
}

uint16_t PapilioSdram::_readDirData() {
    return (uint16_t)(_readReg32(SDRAM_REG_DIR_DATA) & 0xFFFF);
}

void PapilioSdram::_writeDirData(uint16_t data) {
    _writeReg32(SDRAM_REG_DIR_DATA, data);
}

// ----------------------------------------------------------------
// Public API
// ----------------------------------------------------------------

bool PapilioSdram::begin(uint32_t timeoutMs) {
    uint32_t deadline = millis() + timeoutMs;
    while (millis() < deadline) {
        if (isReady()) return true;
        delay(1);
    }
    return false;
}

bool PapilioSdram::isReady() {
    uint32_t csr = _readReg32(SDRAM_REG_CSR);
    return (csr & SDRAM_CSR_INIT_DONE) != 0;
}

uint16_t PapilioSdram::readWord(uint32_t wordAddr) {
    _writeDirAddr(wordAddr);
    // Write DIR_ADDR first, then read DIR_DATA (triggers SDRAM read)
    // Write a dummy 0 to DIR_DATA with we=0 semantics — the gateware
    // treats any WB *read* of DIR_DATA register as a SDRAM read trigger.
    return (uint16_t)(_readReg32(SDRAM_REG_DIR_DATA) & 0xFFFF);
}

void PapilioSdram::writeWord(uint32_t wordAddr, uint16_t data) {
    _writeDirAddr(wordAddr);
    _writeReg32(SDRAM_REG_DIR_DATA, data);
}

void PapilioSdram::writeBlock(uint32_t wordAddr, const uint16_t* data, uint32_t count) {
    while (count > 0) {
        uint16_t page      = (uint16_t)(wordAddr / SDRAM_PAGE_WORDS);
        uint32_t pageOff   = wordAddr % SDRAM_PAGE_WORDS;
        uint32_t chunk     = min((uint32_t)(SDRAM_PAGE_WORDS - pageOff), count);
        uint16_t wbOffset  = _base + SDRAM_WINDOW_OFFSET + (uint16_t)(pageOff * 4);

        _setPage(page);
        for (uint32_t i = 0; i < chunk; i++) {
            wishboneWrite32(wbOffset + (i * 4), data[i]);
        }
        wordAddr += chunk;
        data     += chunk;
        count    -= chunk;
    }
}

void PapilioSdram::readBlock(uint32_t wordAddr, uint16_t* data, uint32_t count) {
    while (count > 0) {
        uint16_t page      = (uint16_t)(wordAddr / SDRAM_PAGE_WORDS);
        uint32_t pageOff   = wordAddr % SDRAM_PAGE_WORDS;
        uint32_t chunk     = min((uint32_t)(SDRAM_PAGE_WORDS - pageOff), count);
        uint16_t wbOffset  = _base + SDRAM_WINDOW_OFFSET + (uint16_t)(pageOff * 4);

        _setPage(page);
        for (uint32_t i = 0; i < chunk; i++) {
            data[i] = (uint16_t)(wishboneRead32(wbOffset + (i * 4)) & 0xFFFF);
        }
        wordAddr += chunk;
        data     += chunk;
        count    -= chunk;
    }
}

void PapilioSdram::fill(uint32_t wordAddr, uint32_t count, uint16_t value) {
    while (count > 0) {
        uint16_t page     = (uint16_t)(wordAddr / SDRAM_PAGE_WORDS);
        uint32_t pageOff  = wordAddr % SDRAM_PAGE_WORDS;
        uint32_t chunk    = min((uint32_t)(SDRAM_PAGE_WORDS - pageOff), count);
        uint16_t wbOffset = _base + SDRAM_WINDOW_OFFSET + (uint16_t)(pageOff * 4);

        _setPage(page);
        for (uint32_t i = 0; i < chunk; i++) {
            wishboneWrite32(wbOffset + (i * 4), value);
        }
        wordAddr += chunk;
        count    -= chunk;
    }
}

void PapilioSdram::startVerify(SdramPattern pattern, uint32_t startWordAddr, uint32_t wordCount) {
    // Clamp to 24-bit max: SDRAM_TOTAL_WORDS (0x01000000) would mask to 0 otherwise
    if (wordCount > 0x00FFFFFFUL) wordCount = 0x00FFFFFFUL;
    _writeReg32(SDRAM_REG_VFY_START, startWordAddr & 0x00FFFFFF);
    _writeReg32(SDRAM_REG_VFY_SIZE,  wordCount);
    _writeReg32(SDRAM_REG_VFY_CTRL,
                ((uint32_t)pattern & 0x3) | SDRAM_VFY_START_BIT);
}

bool PapilioSdram::verifyRunning() {
    uint32_t ctrl = _readReg32(SDRAM_REG_VFY_CTRL);
    return (ctrl & 0xFF) != 0;  // running field
}

bool PapilioSdram::verifyPassed() {
    uint32_t ctrl = _readReg32(SDRAM_REG_VFY_CTRL);
    return (ctrl & SDRAM_VFY_PASS_BIT) != 0;
}

uint32_t PapilioSdram::verifyFailAddress() {
    return _readReg32(SDRAM_REG_VFY_FAIL) & 0x00FFFFFF;
}

bool PapilioSdram::verify(SdramPattern pattern, uint32_t startWordAddr, uint32_t wordCount) {
    startVerify(pattern, startWordAddr, wordCount);
    while (verifyRunning()) {
        delay(10);
        yield();
    }
    return verifyPassed();
}
