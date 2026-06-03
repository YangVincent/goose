# Future work

Items we have infrastructure for but haven't built yet, or have intentionally parked. Notes here so they don't get lost.

## Strap data we don't pull yet

### ECG (MG-only)

WHOOP MG straps support single-lead ECG capture via the metal contact on the strap — the user touches a finger to complete the circuit, the strap records ~30 seconds of ECG samples, and WHOOP's app runs arrhythmia detection.

**What's missing:**
- The BLE command sequence to put the strap into ECG capture mode. WHOOP's app sends a specific command to start the session; we haven't reverse-engineered it. Would need either a BLE sniffer (nRF52840 dongle + Wireshark) capturing a WHOOP-app-initiated ECG session, or APK decompilation to find the command number and payload format.
- The packet format for ECG samples themselves. Likely a custom packet type we haven't decoded.
- An arrhythmia detection algorithm. WHOOP's is FDA-cleared. We'd need to either build our own (medical-grade is a regulatory project) or use it just as a raw waveform recorder.

**Realistic estimate:** Weeks for command-sequence reverse-engineering + packet parsing. Months if we want it to be useful clinically.

### Optical SpO₂ from raw red/IR ADCs

K12/K24 packets give us `spo2_red` and `spo2_ir` raw ADC values. WHOOP computes the SpO₂ percentage server-side from these. We could replicate that with the standard ratio-of-ratios formula:

```
R = (AC_red / DC_red) / (AC_ir / DC_ir)
SpO2 ≈ 110 - 25 * R   (rough Beer-Lambert calibration)
```

Requires periodic AC/DC separation from the raw samples and proper motion-artifact rejection. **~1 week** for a defensible v1.

### Higher-rate HR from R17 optical samples

R17 packets carry up to hundreds of i16 filtered optical samples per packet — much higher resolution than K18's 1Hz historical. We could compute per-beat HR with our own peak detector. **~2-3 days** for a v1.

## Parsing gaps in current K-versions

- **K7 / K9** historical packets: Goose's hr_marker_offset says 27 / 17 respectively, but we don't have OpenWhoop-validated parsers for them. They might have HR at those offsets directly (like K18) or via the K12-style layout. Currently no BPM extraction for K7/K9.
- **K20 raw stream packets**: counted but body not parsed.
- **K11 raw stream packets**: same.
- **K25/K26 pulse information packets**: OpenWhoop marks these as tombstones (no standard BPM field); we receive but don't extract anything.

## UI gaps for infrastructure that already exists

### Smart Alarm

Goose has `writeAlarmCommand` with `.set(alarmID, date, pattern)` plumbed through to BLE command 66 (SET_ALARM_TIME). No UI to set, view, or disable alarms. Need a screen on the Strap tab with:
- Target wake time picker
- Optional window (default 30 min before)
- Slot selector (0-255)
- Pending alarms list using GET_ALARM_TIME (command 67)

### Strap haptics buttons

`writeAlarmCommand` can also fire RUN_ALARM (command 68), which buzzes the strap. Useful as a "find my strap" feature when the strap is somewhere in the room. No button surfaced.

### Skin temperature debug command

Goose has `autoSendDebugSkinTemperatureCommand` (writes 0x73 0x0a) behind an env-var flag. If this reliably gives us skin temp readings, we could surface it as a continuous metric.

## Algorithms we have data for but haven't built

- **Off-wrist filtering**: K12/K24 packets give us a `skin_contact` bit. Once persisted (Phase 4), every aggregation (zones, HRV, SpO₂) should multiply by skin_contact to ignore off-wrist periods. WHOOP doesn't expose this through their cloud API but we have it.
- **Custom HRV from RR intervals**: K12/K24 packets carry RR intervals at offsets 16-23. We could compute RMSSD, SDNN, pNN50 ourselves — currently we just take WHOOP's RMSSD from the cloud API.
- **Pace of Aging**: WHOOP Age delta over a 7-day moving window. Easy follow-up.
- **Step count from continuous IMU**: Goose's Rust core has `step_counter.rs` but the live pipeline doesn't run it. Wiring needed.

## Other parked items

- Period/cycle tracking, Hormonal Insights, journal entries (caffeine/alcohol/mood/sleep aids) — UI + DB schema work.
- Advanced Labs / bloodwork integration — server already has a `bloodwork/` directory; ingestion path needed.
- Strava integration — server has `strava/` already; iOS UI needed.
