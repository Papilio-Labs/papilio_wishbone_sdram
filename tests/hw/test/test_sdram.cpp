#include <Arduino.h>
#include <unity.h>
#include <WishboneSPI.h>
#include <PapilioSdram.h>

// Configure SPI CS pin — adjust for your hardware
static const int WB_CS_PIN = 5;

static WishboneSPI wb(WB_CS_PIN);
static PapilioSdram sdram(&wb, TEST_SDRAM_BASE_ADDR);

// ---------------------------------------------------------------------------
void setUp(void) {
    // Called before each test — nothing needed here
}

void tearDown(void) {
    // Called after each test — nothing needed here
}

// ---------------------------------------------------------------------------
void test_sdram_init_done(void) {
    // Wait up to 10 ms for SDRAM to initialize
    uint32_t t0 = millis();
    while (!sdram.isReady() && (millis() - t0) < 10) delay(1);
    TEST_ASSERT_TRUE_MESSAGE(sdram.isReady(), "SDRAM init_done not asserted within 10 ms");
}

// ---------------------------------------------------------------------------
void test_sdram_write_read(void) {
    const uint32_t addr = 0x001234;
    const uint16_t wval = 0xBEEF;

    sdram.writeWord(addr, wval);
    uint16_t rval = sdram.readWord(addr);
    TEST_ASSERT_EQUAL_HEX16(wval, rval);
}

// ---------------------------------------------------------------------------
void test_sdram_fill(void) {
    const uint32_t base  = 0x002000;
    const uint32_t count = 16;
    const uint16_t val   = 0xA5A5;

    sdram.fill(base, count, val);

    // Spot-check first, middle, and last
    TEST_ASSERT_EQUAL_HEX16(val, sdram.readWord(base));
    TEST_ASSERT_EQUAL_HEX16(val, sdram.readWord(base + count / 2));
    TEST_ASSERT_EQUAL_HEX16(val, sdram.readWord(base + count - 1));
}

// ---------------------------------------------------------------------------
void test_sdram_block_xfer(void) {
    const uint32_t base  = 0x003000;
    const uint32_t count = 256;

    uint16_t txbuf[count];
    uint16_t rxbuf[count];

    for (uint32_t i = 0; i < count; i++) txbuf[i] = (uint16_t)(i ^ 0xA500);

    sdram.writeBlock(base, txbuf, count);
    sdram.readBlock (base, rxbuf, count);

    for (uint32_t i = 0; i < count; i++) {
        if (txbuf[i] != rxbuf[i]) {
            char msg[64];
            snprintf(msg, sizeof(msg), "mismatch at index %lu: got 0x%04X", i, rxbuf[i]);
            TEST_ASSERT_EQUAL_HEX16_MESSAGE(txbuf[i], rxbuf[i], msg);
            return;
        }
    }
}

// ---------------------------------------------------------------------------
void test_sdram_page_boundary(void) {
    // Write across a page boundary (page = 256 words per page in register window)
    // We'll test with a block that starts near end of a page
    const uint32_t base  = SDRAM_PAGE_WORDS - 4;  // Near end of page 0
    const uint32_t count = 16;                      // Crosses into page 1

    uint16_t txbuf[count];
    uint16_t rxbuf[count];
    for (uint32_t i = 0; i < count; i++) txbuf[i] = (uint16_t)(0xC000 + i);

    sdram.writeBlock(base, txbuf, count);
    sdram.readBlock (base, rxbuf, count);

    for (uint32_t i = 0; i < count; i++) {
        char msg[64];
        snprintf(msg, sizeof(msg), "page boundary idx %lu", i);
        TEST_ASSERT_EQUAL_HEX16_MESSAGE(txbuf[i], rxbuf[i], msg);
    }
}

// ---------------------------------------------------------------------------
void test_sdram_verify_pass(void) {
    // Fill small region with walking-ones pattern, then verify
    const uint32_t start = 0x008000;
    const uint32_t size  = 512;

    bool ok = sdram.verify(SDRAM_PAT_WALKING, start, size);
    TEST_ASSERT_TRUE_MESSAGE(ok, "Hardware verify (walking-ones) failed");
}

// ---------------------------------------------------------------------------
void test_sdram_verify_fail(void) {
    // Run ADDR pattern, then corrupt one word; verify should detect FAIL
    const uint32_t start = 0x009000;
    const uint32_t size  = 256;

    // First run a clean verify to establish baseline in SDRAM
    sdram.startVerify(SDRAM_PAT_ADDR, start, size);
    while (sdram.verifyRunning()) delay(10);

    // Corrupt the 10th word
    uint32_t corruptAddr = start + 10;
    sdram.writeWord(corruptAddr, 0xDEAD);

    // Re-run verify — should fail
    sdram.startVerify(SDRAM_PAT_ADDR, start, size);
    while (sdram.verifyRunning()) delay(10);

    TEST_ASSERT_FALSE_MESSAGE(sdram.verifyPassed(), "Verify should have detected corruption");
    TEST_ASSERT_LESS_OR_EQUAL_UINT32_MESSAGE(corruptAddr, sdram.verifyFailAddress(),
        "Fail address should be at or before corrupted word");
}

// ---------------------------------------------------------------------------
void test_sdram_all_banks(void) {
    // Address each of the 4 banks (bits [23:22] of word address)
    const uint32_t offsets[] = {
        0x000000,   // Bank 0
        0x400000,   // Bank 1
        0x800000,   // Bank 2
        0xC00000,   // Bank 3
    };
    const uint16_t vals[] = {0x1111, 0x2222, 0x3333, 0x4444};

    for (int b = 0; b < 4; b++) sdram.writeWord(offsets[b], vals[b]);
    for (int b = 0; b < 4; b++) {
        uint16_t got = sdram.readWord(offsets[b]);
        char msg[32];
        snprintf(msg, sizeof(msg), "bank %d", b);
        TEST_ASSERT_EQUAL_HEX16_MESSAGE(vals[b], got, msg);
    }
}

// ---------------------------------------------------------------------------
void setup(void) {
    delay(2000);  // Give hardware time to settle
    Serial.begin(115200);

    wb.begin();
    sdram.begin();

    UNITY_BEGIN();
    RUN_TEST(test_sdram_init_done);
    RUN_TEST(test_sdram_write_read);
    RUN_TEST(test_sdram_fill);
    RUN_TEST(test_sdram_block_xfer);
    RUN_TEST(test_sdram_page_boundary);
    RUN_TEST(test_sdram_verify_pass);
    RUN_TEST(test_sdram_verify_fail);
    RUN_TEST(test_sdram_all_banks);
    UNITY_END();
}

void loop(void) {}
