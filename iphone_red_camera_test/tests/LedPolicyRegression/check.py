"""Compile the actual firmware LED function with a minimal host fixture.

Only hardware/time/color primitives are stubbed. Decision branches come
directly from updateLedStrip(), not a second Python implementation.
"""
import shutil
import subprocess
import tempfile
from pathlib import Path

root = Path(__file__).resolve().parents[3]
source = (root / "iphone_red_camera_test/esp32_h2d_timelapse_ble/esp32_h2d_timelapse_ble.ino").read_text(encoding="utf-8")
start = source.index("void updateLedStrip() {")
end = source.index("\nvoid setup()", start)
function = source[start:end]
fixture = r'''
#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <iostream>
#include <string>
using std::min;
#define constrain(x, low, high) ((x) < (low) ? (low) : ((x) > (high) ? (high) : (x)))
namespace Config {
constexpr uint32_t LED_REFRESH_MS = 35;
constexpr uint16_t LED_STATUS_COUNT = 3, LED_ANIMATED_COUNT = 4;
constexpr uint16_t LED_ACTIVE_COUNT = 7, LED_PHYSICAL_COUNT = 10;
constexpr uint32_t PRINT_COMPLETE_PULSE_MS = 4000;
constexpr uint8_t LED_IDLE_MAX_SCALE = 102;
}
struct Strip {
    std::array<uint32_t, 10> pixels{};
    static uint32_t Color(uint8_t r, uint8_t g, uint8_t b) {
        return (uint32_t(r) << 16) | (uint32_t(g) << 8) | b;
    }
    void clear() { pixels.fill(0); }
    void setPixelColor(unsigned index, uint32_t color) { pixels.at(index) = color; }
    void show() {}
} ledStrip;
uint32_t currentMillis = 10000, lastLedRefreshAt = 0;
uint32_t settingsPreviewUntil = 0, printCompleteBlueUntil = 0;
uint32_t modeEntryFlashUntil = 0, captureFlashUntil = 0;
uint8_t settingsPreviewType = 0;
int hardwareMode = 0;
bool critical = false, manualFilamentActionActive = false, hardwareHoldPressed = false;
std::string printState = "IDLE";
float printPercent = 0;
uint32_t millis() { return currentMillis; }
bool hasAnyFleetPhysicalCriticalError() { return critical; }
bool isPausedState() { return printState == "PAUSE" || printState == "PAUSED"; }
bool isExplicitlyStoppedState() { return printState == "STOP" || printState == "STOPPED" || printState == "CANCEL" || printState == "CANCELED" || printState == "CANCELLED"; }
bool isActivePrintState(const std::string &state) {
    return state == "RUNNING" || state == "PREPARE" || state == "PREPARING" ||
        state == "PAUSE" || state == "PAUSED" || state == "SLICING" || state == "INIT" || state == "HEATING";
}
uint32_t ledColor(uint8_t r, uint8_t g, uint8_t b) { return Strip::Color(r,g,b); }
uint32_t scaledLedColor(uint8_t r, uint8_t g, uint8_t b, uint8_t scale) {
    return ledColor(uint16_t(r)*scale/255, uint16_t(g)*scale/255, uint16_t(b)*scale/255);
}
void fillStatusLeds(uint32_t color) { for (int i=0; i<3; ++i) ledStrip.setPixelColor(i,color); }
void fillAnimatedLeds(uint32_t color) { for (int i=3; i<7; ++i) ledStrip.setPixelColor(i,color); }
void fillLedStrip(uint32_t color) { fillStatusLeds(color); fillAnimatedLeds(color); }
void drawSettingsLevel() { fillLedStrip(ledColor(255,190,0)); }
uint8_t breathingScale(uint32_t) { return 128; }
uint8_t smoothPulseScale(uint32_t, uint32_t, uint8_t, uint8_t) { return 128; }
float smoothLedProgress(uint32_t) { return printPercent; }
// ACTUAL_FIRMWARE_FUNCTION
void reset(const std::string &state) {
    printState=state; critical=false; manualFilamentActionActive=false;
    hardwareHoldPressed=false; hardwareMode=0; settingsPreviewType=0;
    settingsPreviewUntil=printCompleteBlueUntil=modeEntryFlashUntil=captureFlashUntil=0;
    lastLedRefreshAt=0; printPercent=0;
}
void assertStatus(uint32_t expected) {
    updateLedStrip();
    for (int i=0; i<3; ++i) assert(ledStrip.pixels[i] == expected);
    for (int i=7; i<10; ++i) assert(ledStrip.pixels[i] == 0);
}
int main() {
    const auto idle=scaledLedColor(255,190,0,Config::LED_IDLE_MAX_SCALE);
    const auto red=ledColor(255,0,0), blue=ledColor(0,105,255), green=ledColor(0,255,58);
    reset("FAILED"); assertStatus(idle); // Old cancelled job / AMS drying, no real fault.
    reset("IDLE"); assertStatus(idle);
    reset("FINISH"); assertStatus(idle); // No observed completion timer after boot.
    reset("FAILED"); critical=true; assertStatus(red); // Genuine failure still overrides.
    reset("IDLE"); critical=true; assertStatus(red); // Background-printer fault still overrides.
    reset("PAUSED"); assertStatus(red);
    reset("STOPPED"); assertStatus(red);
    reset("RUNNING"); assertStatus(green);
    reset("HEATING"); assertStatus(green);
    reset("IDLE"); manualFilamentActionActive=true; assertStatus(red);
    reset("FINISH"); printCompleteBlueUntil=currentMillis+500; assertStatus(blue);
    reset("IDLE"); captureFlashUntil=currentMillis+500; assertStatus(blue);
    reset("IDLE"); modeEntryFlashUntil=currentMillis+500; assertStatus(red);
    reset("RUNNING"); critical=true; captureFlashUntil=currentMillis+500; assertStatus(red);
    std::cout << "LED policy: 14 cases passed; real-error priority retained.\n";
}
'''
compiler = shutil.which("g++") or shutil.which("clang++")
if not compiler:
    raise SystemExit("A host C++ compiler is required for the LED regression check")
fixture = fixture.replace("// ACTUAL_FIRMWARE_FUNCTION", function)
with tempfile.TemporaryDirectory(prefix="se-led-policy-") as temporary:
    executable = str(Path(temporary) / "led-policy-check")
    subprocess.run([compiler, "-std=c++17", "-Wall", "-Wextra", "-x", "c++", "-", "-o", executable], input=fixture, text=True, check=True)
    subprocess.run([executable], check=True)
