# SE 9.99 build 178 / ESP32 1.28.1

## Requested changes

- Pause/resume and stop stay visible, but use the same muted gray as the
  inactive alarm button when no recent active print job is reported.
- Pause/resume uses the selected printer's direct state, not stale BLE state.
- AMS humidity and its droplet share one large 64 x 70 pt tile beside the
  filament trays. For a drying-capable AMS, tapping that same tile toggles
  drying; the hours stepper remains in the header. Non-drying AMS humidity is
  read-only. Unknown humidity is a dash, not a fabricated percentage.
- Drying keeps the amber two-second pulse and outward ripple.
- Compact spool tiles are 52 pt wide so all four fit beside the larger humidity
  tile on the small-phone test layout; longer AMS lists remain scrollable.

## LED cause and scope

Read-only status from the user's H2D reported FAILED, print_error=0,
stg_cur=-1, and no HMS items. Firmware 1.28.0 unconditionally included FAILED
in its non-critical red pause/stop branch, so that old job state could make
the LEDs red even while the printer was otherwise idle or drying an AMS.

1.28.1 removes only that unconditional FAILED color. Such a state now uses
standby yellow. Real critical errors still override all other LED branches,
including actual FAILED errors; manual-filament prompts, intentional pause/
stop, completion/capture colors, and physical-mode feedback are unchanged.

No printer commands, sensor mappings, error latching, or historical-hours
bookkeeping were changed. Baseline tag 101 remains untouched.

## Verification

CI compiles the actual updateLedStrip() body with host fixtures for 14 cases,
including idle/cached FAILED, active printing, real-error override, pause,
stop, manual filament prompts, completion, and capture/mode feedback.

Simulator UI tests cover active, idle, paused, AMS-tile layout, nozzle-side
selection, and timelapse layout on two phone sizes. Fixtures never send
printer commands. Release firmware and unsigned IPA are also built.
