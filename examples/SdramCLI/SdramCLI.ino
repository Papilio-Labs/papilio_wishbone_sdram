/*
 * SdramCLI.ino — papilio_wishbone_sdram example
 *
 * Initializes PapilioOS with SDRAM CLI commands. Connect a serial terminal
 * at 115200 baud and type 'sdram help' to see available commands.
 *
 * Hardware: Papilio Retrocade with SDRAM FPGA bitstream
 */

#include <WishboneSPI.h>
#include <PapilioOS.h>
#include <PapilioSdram.h>
#include <PapilioSdramOS.h>

// Adjust CS pin for your hardware
static const int WB_CS_PIN = 5;

WishboneSPI    wb(WB_CS_PIN);
PapilioSdram   sdram(&wb);
PapilioSdramOS sdramOS(&sdram);  // auto-registers 'sdram' commands

void setup() {
    Serial.begin(115200);
    wb.begin();
    PapilioOS.begin(Serial);

    // Wait for SDRAM to complete initialization
    Serial.print("Waiting for SDRAM...");
    uint32_t t0 = millis();
    while (!sdram.isReady()) {
        if (millis() - t0 > 2000) {
            Serial.println(" TIMEOUT (check FPGA bitstream)");
            break;
        }
        delay(1);
    }
    if (sdram.isReady()) {
        Serial.println(" OK");
    }

    Serial.println("Type 'sdram help' for SDRAM commands.");
    Serial.println("Type 'sdram tutorial' for a guided walkthrough.");
}

void loop() {
    PapilioOS.process();
}
