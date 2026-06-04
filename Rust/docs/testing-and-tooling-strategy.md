# Testing and tooling strategy

Inventory of the scriptable Goose tools wired to bridge gates. Each entry names
the CLI binary and the corresponding bridge JSON-RPC method. The numbered
ordering reflects the order in which the tools are typically invoked during
capture, validation, and metric promotion.

## Immediate Tool Order

1. `goose-fixture-index` / `fixtures.build_index`
2. `goose-capture-sanitize` / `capture.sanitize`
3. `goose-capture-sqlite-import` / `capture.import_sqlite`
4. `goose-parser-fixture-runner` / `fixtures.run_parser`
5. `goose-capture-correlation` / `capture.correlation`
6. `goose-capture-arrival-plan` / `capture.arrival_plan`
7. `goose-command-capture-plan` / `commands.capture_plan`
8. `goose-command-validator` / `commands.validate`
9. `goose-metric-input-readiness` / `metrics.input_readiness`
10. `goose-metric-feature-report motion` / `metrics.motion_features`
11. `goose-metric-feature-report heart-rate` / `metrics.heart_rate_features`
12. `goose-metric-feature-report vital-event` / `metrics.vital_event_features`
13. `goose-metric-feature-report step-discovery` / `metrics.step_packet_discovery`
14. `goose-metric-feature-report step-validation` / `metrics.step_capture_validation`
15. `goose-metric-feature-report raw-motion-steps` / `metrics.raw_motion_step_estimate`
16. `goose-metric-feature-report step-counter-ingest` / `metrics.step_counter_ingest`
17. `goose-metric-feature-report step-rollup` / `metrics.step_counter_daily_rollup`
18. `goose-metric-feature-report steps-unavailable-status` / `metrics.activity_unavailable_daily_status`
19. `goose-metric-feature-report calories-unavailable-status` / `metrics.energy_unavailable_daily_status`
20. `goose-metric-feature-report hrv` / `metrics.hrv_features`
21. `goose-metric-feature-report hrv-validation` / `metrics.hrv_capture_validation`
22. `goose-metric-feature-report respiratory-rate-validation` / `metrics.respiratory_rate_capture_validation`
23. `goose-metric-feature-report recovery-sensors` / `metrics.recovery_sensor_discovery`
24. `goose-metric-feature-report recovery-unavailable-status` / `metrics.recovery_unavailable_daily_status`
25. `goose-debug-ws-serve`
26. `goose-metric-feature-report window` / `metrics.window_features`
27. `goose-metric-feature-report resting-hr` / `metrics.resting_hr_features`
28. `goose-metric-feature-report rhr-rollup` / `metrics.resting_hr_daily_rollup`
29. `goose-metric-feature-report rhr-validation` / `metrics.resting_hr_capture_validation`
30. `goose-metric-feature-report sleep-score` / `metrics.sleep_score_from_features`
31. `goose-metric-feature-report recovery-score` / `metrics.recovery_score_from_features`
32. `goose-metric-feature-report strain-score` / `metrics.strain_score_from_features`
33. `goose-metric-feature-report stress-score` / `metrics.stress_score_from_features`
34. `goose-local-health-validation-suite`

## Notes

This doc is verified by `tests/tooling_inventory_tests.rs`. If you add or remove
a tool, update both `REQUIRED_DOC_ENTRIES` in the test and the numbered list
above so the entries stay aligned. The numbered ordering at positions 6 and 25
is asserted explicitly (capture arrival plan and debug WebSocket serve,
respectively).
