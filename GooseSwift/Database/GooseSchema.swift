import Foundation
import SQLite3

/// Schema + migrations for goose.sqlite. Ported verbatim from
/// Rust/core/src/store.rs migrate(). The big SQL batch is identical to
/// the Rust version so an existing DB at v25 is a no-op; the
/// ensure_*_columns helpers handle incremental column additions on
/// older DBs using the same check-before-add pattern Rust used.
///
/// Called once from app launch (see AppShellView). Idempotent —
/// every CREATE TABLE / CREATE INDEX is IF NOT EXISTS, every ALTER
/// is gated on a PRAGMA table_info check.
enum GooseSchema {

  /// Run the schema batch + every ensure_* helper. Safe to call
  /// repeatedly. Returns the post-migration schema version (== 25 for
  /// the version this port targets).
  static func migrate(db: GooseDB) throws -> Int {
    try db.execute(Self.schemaBatch)
    try ensureRawEvidenceColumns(db)
    try dropDecodedFrameParsedPayloadJsonColumn(db)
    try ensureDecodedFrameColumns(db)
    try ensureStrapEventsColumns(db)
    try ensureCommandResponsesColumns(db)
    try ensureConsoleLogsColumns(db)
    try ensureAlgorithmDefinitionColumns(db)
    try ensureStepCounterSampleColumns(db)
    try ensureV24TypedTableColumns(db)
    return try db.schemaVersion()
  }

  // MARK: - The main schema batch (every CREATE TABLE / CREATE INDEX
  // gated by IF NOT EXISTS, so this is a no-op after the first run).

  private static let schemaBatch: String = """
            PRAGMA foreign_keys = ON;

            CREATE TABLE IF NOT EXISTS goose_schema_migrations (
                version INTEGER PRIMARY KEY,
                applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS raw_evidence (
                evidence_id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                captured_at TEXT NOT NULL,
                device_model TEXT NOT NULL,
                payload_hex TEXT NOT NULL,
                sha256 TEXT NOT NULL,
                sensitivity TEXT NOT NULL,
                capture_session_id TEXT REFERENCES capture_sessions(session_id) ON DELETE SET NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS decoded_frames (
                frame_id TEXT PRIMARY KEY,
                evidence_id TEXT NOT NULL REFERENCES raw_evidence(evidence_id) ON DELETE CASCADE,
                device_type TEXT NOT NULL,
                raw_len INTEGER NOT NULL,
                header_len INTEGER NOT NULL,
                declared_len INTEGER NOT NULL,
                payload_hex TEXT NOT NULL,
                payload_crc_hex TEXT NOT NULL,
                header_crc_valid INTEGER NOT NULL,
                payload_crc_valid INTEGER NOT NULL,
                packet_type INTEGER,
                packet_type_name TEXT,
                sequence INTEGER,
                command_or_event INTEGER,
                parser_version TEXT NOT NULL,
                warnings_json TEXT NOT NULL,
                packet_family TEXT,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS algorithm_definitions (
                algorithm_id TEXT NOT NULL,
                version TEXT NOT NULL,
                metric_family TEXT NOT NULL,
                display_name TEXT NOT NULL DEFAULT '',
                implementation TEXT NOT NULL DEFAULT '',
                license TEXT NOT NULL DEFAULT '',
                input_schema TEXT NOT NULL,
                output_schema TEXT NOT NULL,
                input_requirements_json TEXT NOT NULL DEFAULT '{}',
                params_json TEXT NOT NULL,
                quality_gates_json TEXT NOT NULL DEFAULT '[]',
                status TEXT NOT NULL DEFAULT 'experimental',
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                PRIMARY KEY (algorithm_id, version)
            );

            CREATE TABLE IF NOT EXISTS algorithm_runs (
                run_id TEXT PRIMARY KEY,
                algorithm_id TEXT NOT NULL,
                version TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time TEXT NOT NULL,
                output_json TEXT NOT NULL,
                quality_flags_json TEXT NOT NULL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                FOREIGN KEY (algorithm_id, version)
                    REFERENCES algorithm_definitions(algorithm_id, version)
            );

            CREATE TABLE IF NOT EXISTS command_validation_records (
                command TEXT PRIMARY KEY,
                risk_gate TEXT NOT NULL,
                direct_send_ready INTEGER NOT NULL,
                report_json TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS capture_sessions (
                session_id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                started_at_unix_ms INTEGER NOT NULL,
                ended_at_unix_ms INTEGER,
                device_model TEXT NOT NULL,
                active_device_id TEXT,
                status TEXT NOT NULL,
                frame_count INTEGER NOT NULL DEFAULT 0,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS activity_sessions (
                session_id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                activity_type TEXT NOT NULL,
                external_activity_type_code TEXT,
                external_activity_type_name TEXT,
                custom_label TEXT,
                confidence REAL NOT NULL,
                detection_method TEXT NOT NULL,
                sync_status TEXT NOT NULL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_activity_sessions_by_window
                ON activity_sessions(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_activity_sessions_by_type
                ON activity_sessions(activity_type);
            CREATE INDEX IF NOT EXISTS idx_activity_sessions_by_source
                ON activity_sessions(source);
            CREATE INDEX IF NOT EXISTS idx_activity_sessions_by_sync_status
                ON activity_sessions(sync_status);

            CREATE TABLE IF NOT EXISTS activity_metrics (
                metric_id TEXT PRIMARY KEY,
                activity_session_id TEXT NOT NULL REFERENCES activity_sessions(session_id) ON DELETE CASCADE,
                metric_name TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_activity_metrics_by_session
                ON activity_metrics(activity_session_id);
            CREATE INDEX IF NOT EXISTS idx_activity_metrics_by_name
                ON activity_metrics(metric_name);

            CREATE TABLE IF NOT EXISTS daily_activity_metrics (
                daily_metric_id TEXT PRIMARY KEY,
                date_key TEXT NOT NULL,
                timezone TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                steps INTEGER,
                active_kcal REAL,
                resting_kcal REAL,
                total_kcal REAL,
                average_cadence_spm REAL,
                source_kind TEXT NOT NULL,
                confidence REAL NOT NULL,
                inputs_json TEXT NOT NULL DEFAULT '{}',
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_daily_activity_metrics_by_date
                ON daily_activity_metrics(date_key);
            CREATE INDEX IF NOT EXISTS idx_daily_activity_metrics_by_window
                ON daily_activity_metrics(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_daily_activity_metrics_by_source_kind
                ON daily_activity_metrics(source_kind);

            CREATE TABLE IF NOT EXISTS hourly_activity_metrics (
                hourly_metric_id TEXT PRIMARY KEY,
                date_key TEXT NOT NULL,
                timezone TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                steps INTEGER,
                active_kcal REAL,
                resting_kcal REAL,
                total_kcal REAL,
                average_cadence_spm REAL,
                source_kind TEXT NOT NULL,
                confidence REAL NOT NULL,
                inputs_json TEXT NOT NULL DEFAULT '{}',
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_hourly_activity_metrics_by_date
                ON hourly_activity_metrics(date_key);
            CREATE INDEX IF NOT EXISTS idx_hourly_activity_metrics_by_window
                ON hourly_activity_metrics(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_hourly_activity_metrics_by_source_kind
                ON hourly_activity_metrics(source_kind);

            CREATE TABLE IF NOT EXISTS daily_recovery_metrics (
                daily_metric_id TEXT PRIMARY KEY,
                date_key TEXT NOT NULL,
                timezone TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                resting_hr_bpm REAL,
                hrv_rmssd_ms REAL,
                respiratory_rate_rpm REAL,
                oxygen_saturation_percent REAL,
                skin_temperature_delta_c REAL,
                source_kind TEXT NOT NULL,
                confidence REAL NOT NULL,
                inputs_json TEXT NOT NULL DEFAULT '{}',
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_daily_recovery_metrics_by_date
                ON daily_recovery_metrics(date_key);
            CREATE INDEX IF NOT EXISTS idx_daily_recovery_metrics_by_window
                ON daily_recovery_metrics(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_daily_recovery_metrics_by_source_kind
                ON daily_recovery_metrics(source_kind);

            CREATE TABLE IF NOT EXISTS metric_provenance (
                provenance_id TEXT PRIMARY KEY,
                metric_scope TEXT NOT NULL,
                metric_id TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                source_detail TEXT NOT NULL DEFAULT '',
                confidence REAL,
                inputs_json TEXT NOT NULL DEFAULT '{}',
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_metric_provenance_by_metric
                ON metric_provenance(metric_scope, metric_id);
            CREATE INDEX IF NOT EXISTS idx_metric_provenance_by_source_kind
                ON metric_provenance(source_kind);

            CREATE TABLE IF NOT EXISTS metric_debug_features (
                feature_id TEXT PRIMARY KEY,
                metric_family TEXT NOT NULL,
                feature_name TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                source_kind TEXT NOT NULL,
                confidence REAL,
                feature_json TEXT NOT NULL DEFAULT '{}',
                inputs_json TEXT NOT NULL DEFAULT '{}',
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_metric_debug_features_by_family
                ON metric_debug_features(metric_family, feature_name);
            CREATE INDEX IF NOT EXISTS idx_metric_debug_features_by_window
                ON metric_debug_features(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_metric_debug_features_by_source_kind
                ON metric_debug_features(source_kind);

            CREATE TABLE IF NOT EXISTS step_counter_samples (
                sample_id TEXT PRIMARY KEY,
                sample_time_unix_ms INTEGER NOT NULL,
                counter_value INTEGER NOT NULL,
                cadence_spm REAL,
                activity_state TEXT,
                source_kind TEXT NOT NULL,
                packet_family TEXT NOT NULL DEFAULT '',
                json_path TEXT NOT NULL DEFAULT '',
                frame_id TEXT,
                evidence_id TEXT,
                capture_session_id TEXT,
                quality_flags_json TEXT NOT NULL DEFAULT '[]',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_step_counter_samples_by_time
                ON step_counter_samples(sample_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_step_counter_samples_by_field
                ON step_counter_samples(packet_family, json_path, sample_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_step_counter_samples_by_source_kind
                ON step_counter_samples(source_kind);

            CREATE TABLE IF NOT EXISTS activity_intervals (
                interval_id TEXT PRIMARY KEY,
                activity_session_id TEXT NOT NULL REFERENCES activity_sessions(session_id) ON DELETE CASCADE,
                interval_type TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                sequence INTEGER NOT NULL,
                metadata_json TEXT NOT NULL DEFAULT '{}',
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_activity_intervals_by_session
                ON activity_intervals(activity_session_id);
            CREATE INDEX IF NOT EXISTS idx_activity_intervals_by_type
                ON activity_intervals(interval_type);

            CREATE TABLE IF NOT EXISTS activity_labels (
                label_id TEXT PRIMARY KEY,
                activity_session_id TEXT NOT NULL REFERENCES activity_sessions(session_id) ON DELETE CASCADE,
                label_type TEXT NOT NULL,
                value TEXT NOT NULL,
                source TEXT NOT NULL,
                confidence REAL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_activity_labels_by_session
                ON activity_labels(activity_session_id);
            CREATE INDEX IF NOT EXISTS idx_activity_labels_by_type
                ON activity_labels(label_type);

            CREATE TABLE IF NOT EXISTS external_sleep_sessions (
                sleep_id TEXT PRIMARY KEY,
                source TEXT NOT NULL,
                platform TEXT NOT NULL,
                platform_record_id TEXT,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                timezone TEXT,
                stage_summary_json TEXT NOT NULL DEFAULT '{}',
                confidence REAL NOT NULL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                UNIQUE(platform, platform_record_id)
            );

            CREATE INDEX IF NOT EXISTS idx_external_sleep_sessions_by_window
                ON external_sleep_sessions(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_external_sleep_sessions_by_platform
                ON external_sleep_sessions(platform);
            CREATE INDEX IF NOT EXISTS idx_external_sleep_sessions_by_source
                ON external_sleep_sessions(source);

            CREATE TABLE IF NOT EXISTS external_sleep_stages (
                stage_id TEXT PRIMARY KEY,
                sleep_id TEXT NOT NULL REFERENCES external_sleep_sessions(sleep_id) ON DELETE CASCADE,
                stage_kind TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                confidence REAL NOT NULL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_external_sleep_stages_by_sleep
                ON external_sleep_stages(sleep_id);
            CREATE INDEX IF NOT EXISTS idx_external_sleep_stages_by_window
                ON external_sleep_stages(start_time_unix_ms, end_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_external_sleep_stages_by_kind
                ON external_sleep_stages(stage_kind);

            CREATE TABLE IF NOT EXISTS sleep_correction_labels (
                label_id TEXT PRIMARY KEY,
                sleep_id TEXT,
                label_type TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                value_json TEXT NOT NULL,
                source TEXT NOT NULL,
                confidence REAL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE INDEX IF NOT EXISTS idx_sleep_correction_labels_by_sleep
                ON sleep_correction_labels(sleep_id);
            CREATE INDEX IF NOT EXISTS idx_sleep_correction_labels_by_type
                ON sleep_correction_labels(label_type);
            CREATE INDEX IF NOT EXISTS idx_sleep_correction_labels_by_window
                ON sleep_correction_labels(start_time_unix_ms, end_time_unix_ms);

            CREATE TABLE IF NOT EXISTS metric_values (
                metric_value_id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL REFERENCES algorithm_runs(run_id) ON DELETE CASCADE,
                metric_family TEXT NOT NULL,
                name TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                start_time TEXT NOT NULL,
                end_time TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS metric_components (
                metric_component_id TEXT PRIMARY KEY,
                run_id TEXT NOT NULL REFERENCES algorithm_runs(run_id) ON DELETE CASCADE,
                component_name TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                contribution_json TEXT NOT NULL DEFAULT '{}',
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS calibration_labels (
                label_id TEXT PRIMARY KEY,
                metric_family TEXT NOT NULL,
                label_source TEXT NOT NULL,
                captured_at TEXT NOT NULL,
                value REAL NOT NULL,
                unit TEXT NOT NULL,
                provenance_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS calibration_runs (
                calibration_run_id TEXT PRIMARY KEY,
                algorithm_id TEXT NOT NULL,
                version TEXT NOT NULL,
                train_start TEXT NOT NULL,
                train_end TEXT NOT NULL,
                holdout_start TEXT NOT NULL,
                holdout_end TEXT NOT NULL,
                metrics_json TEXT NOT NULL,
                params_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                FOREIGN KEY (algorithm_id, version)
                    REFERENCES algorithm_definitions(algorithm_id, version)
            );

            CREATE TABLE IF NOT EXISTS algorithm_preferences (
                scope TEXT NOT NULL,
                metric_family TEXT NOT NULL,
                algorithm_id TEXT NOT NULL,
                version TEXT NOT NULL,
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                PRIMARY KEY (scope, metric_family),
                FOREIGN KEY (algorithm_id, version)
                    REFERENCES algorithm_definitions(algorithm_id, version)
            );

            CREATE TABLE IF NOT EXISTS debug_sessions (
                session_id TEXT PRIMARY KEY,
                started_at_unix_ms INTEGER NOT NULL,
                bridge_url TEXT NOT NULL,
                bind_host TEXT NOT NULL,
                token_required INTEGER NOT NULL,
                token_present INTEGER NOT NULL,
                remote_bind_enabled INTEGER NOT NULL,
                visible_remote_bind_toggle INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS debug_commands (
                command_id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES debug_sessions(session_id) ON DELETE CASCADE,
                schema TEXT NOT NULL,
                command TEXT NOT NULL,
                args_json TEXT NOT NULL,
                dry_run INTEGER NOT NULL,
                received_at_unix_ms INTEGER NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS debug_events (
                session_id TEXT NOT NULL REFERENCES debug_sessions(session_id) ON DELETE CASCADE,
                sequence INTEGER NOT NULL,
                schema TEXT NOT NULL,
                time_unix_ms INTEGER NOT NULL,
                source TEXT NOT NULL,
                level TEXT NOT NULL,
                topic TEXT NOT NULL,
                message TEXT NOT NULL,
                command_id TEXT REFERENCES debug_commands(command_id),
                data_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                PRIMARY KEY (session_id, sequence)
            );

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (1);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (2);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (3);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (4);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (5);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (6);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (7);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (8);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (9);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (10);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (11);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (12);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (13);
            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (14);

            -- v15: Swift-side data caches consolidated into SQLite. Replaces
            -- heart-rate-samples.json, sensor-samples.json, step-estimates.json,
            -- r17-samples.json, imu-samples.json. All include synced_at NULL
            -- columns so a future one-way sync daemon can drain them to the
            -- server.

            CREATE TABLE IF NOT EXISTS hr_samples (
                sample_id TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                bpm INTEGER NOT NULL,
                source TEXT NOT NULL DEFAULT '',
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_hr_samples_captured_at
                ON hr_samples(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_hr_samples_unsynced
                ON hr_samples(synced_at) WHERE synced_at IS NULL;

            CREATE TABLE IF NOT EXISTS sensor_samples (
                sample_id TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                source TEXT NOT NULL,
                bpm INTEGER,
                rr_intervals_ms TEXT,
                ppg_green INTEGER,
                ppg_red_ir INTEGER,
                spo2_red INTEGER,
                spo2_ir INTEGER,
                spo2_pct INTEGER,
                skin_temp_raw INTEGER,
                ambient_light INTEGER,
                led_drive_1 INTEGER,
                led_drive_2 INTEGER,
                signal_quality INTEGER,
                skin_contact INTEGER,
                accel_gravity TEXT,
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_sensor_samples_captured_at
                ON sensor_samples(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_sensor_samples_unsynced
                ON sensor_samples(synced_at) WHERE synced_at IS NULL;

            CREATE TABLE IF NOT EXISTS step_days (
                date_key TEXT PRIMARY KEY,
                active_seconds REAL NOT NULL,
                estimated_steps REAL NOT NULL,
                packet_count INTEGER NOT NULL,
                last_updated_ms INTEGER NOT NULL,
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            CREATE TABLE IF NOT EXISTS imported_daily_summary (
                date_key TEXT PRIMARY KEY,
                recovery_score REAL,
                hrv_rmssd_ms REAL,
                resting_hr_bpm REAL,
                spo2_pct REAL,
                skin_temp_c REAL,
                sleep_performance_pct REAL,
                sleep_efficiency_pct REAL,
                sleep_in_bed_ms INTEGER,
                sleep_awake_ms INTEGER,
                sleep_light_ms INTEGER,
                sleep_deep_ms INTEGER,
                sleep_rem_ms INTEGER,
                sleep_cycle_count INTEGER,
                sleep_disturbance_count INTEGER,
                sleep_need_baseline_ms INTEGER,
                sleep_need_from_debt_ms INTEGER,
                sleep_need_from_strain_ms INTEGER,
                sleep_need_from_nap_ms INTEGER,
                strain_score REAL,
                strain_kilojoules REAL,
                source TEXT NOT NULL DEFAULT 'whoop_cloud_import',
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_imported_daily_summary_date
                ON imported_daily_summary(date_key);

            CREATE TABLE IF NOT EXISTS sleep_audio_events (
                event_id TEXT PRIMARY KEY,
                started_at_ms INTEGER NOT NULL,
                duration_ms INTEGER NOT NULL,
                peak_db REAL NOT NULL,
                kind TEXT NOT NULL,
                file_path TEXT,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_sleep_audio_events_started_at
                ON sleep_audio_events(started_at_ms);

            -- One row per STRAP_CONDITION_REPORT (~every 10 minutes). The
            -- band reports byte 10 = 0x01 when worn, 0x00 when off-body.
            -- Used to filter off-wrist samples from HR/HRV/sleep analyses.
            CREATE TABLE IF NOT EXISTS strap_worn_samples (
                captured_at_ms INTEGER PRIMARY KEY,
                worn INTEGER NOT NULL,  -- 0 or 1
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_strap_worn_samples_captured_at
                ON strap_worn_samples(captured_at_ms);

            -- Every strap event mirrored to a typed table. Includes the
            -- decoded event_id + event_name, the embedded packet
            -- timestamp, and the raw data bytes. Specific event types
            -- (STRAP_CONDITION_REPORT, BATTERY_LEVEL, CHARGING_ON/OFF,
            -- WRIST_OFF, etc.) get their fields promoted to columns; the
            -- rest stay in data_hex for later decode.
            CREATE TABLE IF NOT EXISTS strap_events (
                event_uid TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                event_id INTEGER,
                event_name TEXT,
                timestamp_seconds INTEGER,
                timestamp_subseconds INTEGER,
                worn INTEGER,
                battery_pct INTEGER,
                data_hex TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_strap_events_captured_at
                ON strap_events(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_strap_events_by_id
                ON strap_events(event_id);

            -- K26 'pulse_information_packet' samples, 24 i16 LE per
            -- packet. Mirrors raw_r17_packets / raw_imu_packets.
            CREATE TABLE IF NOT EXISTS raw_k26_packets (
                packet_id TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                counter INTEGER,
                sample_count INTEGER,
                samples_blob BLOB NOT NULL,
                source TEXT NOT NULL,
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_raw_k26_captured_at
                ON raw_k26_packets(captured_at_ms);

            -- Firmware console-log lines from the strap, decoded best-
            -- effort. data_hex is preserved so we can re-parse later if
            -- the line format changes.
            CREATE TABLE IF NOT EXISTS console_logs (
                log_uid TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                level TEXT,
                text TEXT,
                data_hex TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_console_logs_captured_at
                ON console_logs(captured_at_ms);

            -- METADATA packets (type 49) — keep the raw bytes + the
            -- per-packet timestamp so future decoders can analyse them.
            CREATE TABLE IF NOT EXISTS metadata_packets (
                packet_uid TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                packet_type INTEGER NOT NULL,
                data_hex TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_metadata_packets_captured_at
                ON metadata_packets(captured_at_ms);

            -- Catch-all safety net. In steady state this table should be
            -- empty -- every known packet type the strap sends has a
            -- dedicated typed mirror (hr_samples, sensor_samples,
            -- raw_imu_packets, raw_r17_packets, raw_k26_packets,
            -- strap_events, strap_commands, command_responses,
            -- metadata_packets, console_logs, hrv_samples). Anything
            -- landing here is by definition a packet type we don't
            -- recognise yet, which is a signal to add a typed table.
            CREATE TABLE IF NOT EXISTS raw_packet_bodies (
                packet_uid TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                packet_type INTEGER NOT NULL,
                packet_type_name TEXT,
                sequence INTEGER,
                command_or_event INTEGER,
                payload_hex TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_raw_packet_bodies_captured_at
                ON raw_packet_bodies(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_raw_packet_bodies_packet_type
                ON raw_packet_bodies(packet_type);

            -- Typed mirror for every COMMAND_RESPONSE (type 36) packet.
            -- The protocol parser produces (response_to_command,
            -- origin_sequence, result_code, data_hex); we surface them
            -- here so command audit / debugging can query without
            -- parsing JSON.
            CREATE TABLE IF NOT EXISTS command_responses (
                response_uid TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                response_to_command INTEGER,
                response_to_command_name TEXT,
                origin_sequence INTEGER,
                result_code INTEGER,
                data_hex TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_command_responses_captured_at
                ON command_responses(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_command_responses_command
                ON command_responses(response_to_command);

            CREATE TABLE IF NOT EXISTS raw_r17_packets (
                packet_id TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                flags INTEGER,
                sample_count INTEGER,
                channels_or_gain TEXT,
                samples_min INTEGER,
                samples_max INTEGER,
                samples_sum INTEGER,
                samples_blob BLOB NOT NULL,
                source TEXT NOT NULL,
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_raw_r17_captured_at
                ON raw_r17_packets(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_raw_r17_unsynced
                ON raw_r17_packets(synced_at) WHERE synced_at IS NULL;

            CREATE TABLE IF NOT EXISTS raw_imu_packets (
                packet_id TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                kind TEXT NOT NULL,
                heart_rate_bpm INTEGER,
                axes_meta_json TEXT NOT NULL,
                samples_blob BLOB NOT NULL,
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_raw_imu_captured_at
                ON raw_imu_packets(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_raw_imu_unsynced
                ON raw_imu_packets(synced_at) WHERE synced_at IS NULL;

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (15);

            -- v16: HRV samples. Goose's HRVSeriesStore used to write to
            -- hrv-samples.json; this is the SQLite replacement.

            CREATE TABLE IF NOT EXISTS hrv_samples (
                sample_id TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                rmssd_ms REAL NOT NULL,
                rr_interval_count INTEGER NOT NULL,
                source TEXT NOT NULL DEFAULT '',
                synced_at INTEGER,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_hrv_samples_captured_at
                ON hrv_samples(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_hrv_samples_unsynced
                ON hrv_samples(synced_at) WHERE synced_at IS NULL;

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (16);
            PRAGMA user_version = 16;

            -- v17: close the typed-mirror gaps. Every packet variant the
            -- protocol parser knows about now has its own typed table:
            --   * COMMAND (35) + PUFFIN_COMMAND (37) -> strap_commands
            --   * PUFFIN_COMMAND_RESPONSE (38) shares command_responses
            --     (distinguished by the new packet_type column)
            --   * RELATIVE_PUFFIN_EVENTS (53) + PUFFIN_EVENTS_FROM_STRAP
            --     (54) share strap_events (new packet_type column)
            --   * RELATIVE_BATTERY_PACK_CONSOLE_LOGS (55) shares
            --     console_logs (new packet_type column)
            -- raw_packet_bodies is now reserved for genuinely unknown
            -- packet types, not a permanent home for known ones.
            CREATE TABLE IF NOT EXISTS strap_commands (
                command_uid TEXT PRIMARY KEY,
                captured_at_ms INTEGER NOT NULL,
                packet_type INTEGER NOT NULL,
                command INTEGER,
                command_name TEXT,
                sequence INTEGER,
                data_hex TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_strap_commands_captured_at
                ON strap_commands(captured_at_ms);
            CREATE INDEX IF NOT EXISTS idx_strap_commands_command
                ON strap_commands(command);
            CREATE INDEX IF NOT EXISTS idx_strap_commands_packet_type
                ON strap_commands(packet_type);

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (17);
            PRAGMA user_version = 17;

            -- v18: typed packet_family column on decoded_frames. Computed
            -- once at insert time from the ParsedPayload so downstream
            -- queries (capture correlation, manifest scaffolding, local
            -- health validation) don't have to JSON-introspect or
            -- re-parse payload_hex at query time. ensure_decoded_frame_columns
            -- adds the column for already-migrated databases.

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (18);
            PRAGMA user_version = 18;

            -- v19: drop the decoded_frames.parsed_payload_json column.
            -- The typed mirror tables hold every decoded field and the
            -- packet_family column tells downstream queries the group-by
            -- key. payload_hex is preserved as the canonical raw evidence;
            -- callers that need the structured payload re-parse it via
            -- protocol::parsed_payload_from_payload_hex(). The ALTER TABLE
            -- DROP COLUMN below is executed unconditionally on every
            -- migration pass; SQLite ignores it if the column is already
            -- gone.

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (19);
            PRAGMA user_version = 19;

            -- v20: typed mirror for sleep readings, one row per
            -- SleepSessionStore session. The bridge method
            -- sleep.compute_reading writes here when the iOS "End Sleep"
            -- button is tapped (and during retroactive backfills).
            CREATE TABLE IF NOT EXISTS sleep_readings (
                session_id TEXT PRIMARY KEY,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                time_in_bed_minutes INTEGER NOT NULL,
                total_sleep_minutes INTEGER NOT NULL,
                deep_minutes INTEGER NOT NULL,
                light_minutes INTEGER NOT NULL,
                awake_minutes INTEGER NOT NULL,
                efficiency REAL NOT NULL,
                deep_share_of_sleep REAL NOT NULL,
                awake_share_of_bed REAL NOT NULL,
                onset_latency_minutes INTEGER,
                wake_after_sleep_onset_minutes INTEGER NOT NULL,
                hr_mean_bpm REAL,
                hr_min_bpm INTEGER,
                hr_max_bpm INTEGER,
                hrv_mean_rmssd_ms REAL NOT NULL,
                hrv_sample_count INTEGER NOT NULL,
                movement_total_intensity REAL NOT NULL,
                movement_peak_minute REAL NOT NULL,
                movement_burst_minutes INTEGER NOT NULL,
                duration_score REAL NOT NULL,
                efficiency_score REAL NOT NULL,
                depth_score REAL NOT NULL,
                hrv_score REAL NOT NULL,
                restfulness_score REAL NOT NULL,
                sleep_score REAL NOT NULL,
                resting_bpm_used INTEGER NOT NULL,
                hrv_baseline_ms_used REAL NOT NULL,
                need_hours REAL NOT NULL,
                reading_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_sleep_readings_start
                ON sleep_readings(start_time_unix_ms);
            CREATE INDEX IF NOT EXISTS idx_sleep_readings_end
                ON sleep_readings(end_time_unix_ms);

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (20);
            PRAGMA user_version = 20;

            -- v21: typed mirror for recovery readings, keyed by the same
            -- sleep session_id as sleep_readings. recovery.compute_from_sleep_reading
            -- writes here right after sleep.compute_reading lands; one
            -- row per night.
            CREATE TABLE IF NOT EXISTS recovery_readings (
                session_id TEXT PRIMARY KEY,
                date_key TEXT NOT NULL,
                algorithm_id TEXT NOT NULL,
                algorithm_version TEXT NOT NULL,
                start_time_unix_ms INTEGER NOT NULL,
                end_time_unix_ms INTEGER NOT NULL,
                recovery_score REAL NOT NULL,
                hrv_score REAL NOT NULL,
                rhr_score REAL NOT NULL,
                sleep_score REAL NOT NULL,
                respiratory_score REAL NOT NULL,
                temperature_score REAL NOT NULL,
                prior_strain_score REAL NOT NULL,
                hrv_rmssd_ms REAL NOT NULL,
                hrv_baseline_rmssd_ms REAL NOT NULL,
                resting_hr_bpm REAL NOT NULL,
                resting_hr_baseline_bpm REAL NOT NULL,
                respiratory_rate_rpm REAL NOT NULL,
                respiratory_rate_baseline_rpm REAL NOT NULL,
                skin_temp_delta_c REAL NOT NULL,
                prior_strain_0_to_21 REAL NOT NULL,
                baseline_nights_used INTEGER NOT NULL,
                reading_json TEXT NOT NULL,
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_recovery_readings_date
                ON recovery_readings(date_key);

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (21);
            PRAGMA user_version = 21;

            -- v22: typed mirror for one-row-per-day strain readings.
            -- Past days are finalized into this table by the iOS
            -- StrainFinalizer (which runs on every foreground after
            -- midnight). Today stays in-memory (live, accumulating)
            -- via DayStrainStore.today. WhoopHomeView reads from this
            -- table for any past day and from .today for today.
            CREATE TABLE IF NOT EXISTS daily_strain_readings (
                date_key TEXT PRIMARY KEY,
                strain_score REAL NOT NULL,
                background_strain REAL NOT NULL,
                background_effective_kj REAL NOT NULL,
                workout_count INTEGER NOT NULL,
                workout_effective_kj REAL NOT NULL,
                workout_strain_sum REAL NOT NULL,
                sample_count INTEGER NOT NULL,
                last_sample_at_unix_ms INTEGER,
                reading_json TEXT NOT NULL,
                finalized_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );
            CREATE INDEX IF NOT EXISTS idx_daily_strain_readings_date
                ON daily_strain_readings(date_key);

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (22);
            PRAGMA user_version = 22;

            -- v23: per-30s-epoch hypnogram persistence. Filled by
            -- sleep.compute_reading (called from sleep_reading.rs) so the
            -- SleepDetailView hypnogram is rendered straight from sqlite
            -- instead of recomputed on every view appear.
            CREATE TABLE IF NOT EXISTS sleep_epochs (
                session_id TEXT NOT NULL,
                epoch_index INTEGER NOT NULL,
                epoch_start_unix_ms INTEGER NOT NULL,
                epoch_end_unix_ms INTEGER NOT NULL,
                stage TEXT NOT NULL CHECK (stage IN ('wake','light','rem','deep','n/a')),
                hr_mean_bpm REAL,
                hr_std_bpm REAL,
                rmssd_ms REAL,
                movement_intensity REAL,
                PRIMARY KEY (session_id, epoch_index),
                FOREIGN KEY (session_id) REFERENCES sleep_readings(session_id) ON DELETE CASCADE
            );
            CREATE INDEX IF NOT EXISTS idx_sleep_epochs_start
                ON sleep_epochs(epoch_start_unix_ms);

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (23);
            PRAGMA user_version = 23;

            -- v24: source columns + WHOOP-shaped sleep fields. Schema
            -- ADD COLUMNs are handled idempotently in
            -- ensure_v24_typed_table_columns below — SQLite doesn't have
            -- ADD COLUMN IF NOT EXISTS and this whole batch re-runs on
            -- every open, so unconditional ALTERs would throw the second
            -- time. CREATE INDEX on date_key moves there too because the
            -- column has to exist before the index can be built.

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (24);
            PRAGMA user_version = 24;

            -- v25: typed mirror for daily vitals (SpO2, skin temp).
            -- Until local K18 vitals extraction lands the only writer
            -- is the WHOOP import. Local writer is a follow-up TODO.
            CREATE TABLE IF NOT EXISTS daily_vitals_readings (
                date_key TEXT PRIMARY KEY,
                spo2_pct REAL,
                skin_temp_c REAL,
                source TEXT NOT NULL DEFAULT 'goose.local',
                created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
                updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
            );

            INSERT OR IGNORE INTO goose_schema_migrations(version) VALUES (25);
            PRAGMA user_version = 25;
"""

  // MARK: - Idempotent column additions (Rust's ensure_*_columns)

  private static func ensureRawEvidenceColumns(_ db: GooseDB) throws {
    if !db.tableHasColumn("raw_evidence", column: "capture_session_id") {
      try db.execute(
        "ALTER TABLE raw_evidence ADD COLUMN capture_session_id TEXT REFERENCES capture_sessions(session_id) ON DELETE SET NULL"
      )
    }
  }

  private static func dropDecodedFrameParsedPayloadJsonColumn(_ db: GooseDB) throws {
    if db.tableHasColumn("decoded_frames", column: "parsed_payload_json") {
      try db.execute("ALTER TABLE decoded_frames DROP COLUMN parsed_payload_json")
    }
  }

  private static func ensureDecodedFrameColumns(_ db: GooseDB) throws {
    if !db.tableHasColumn("decoded_frames", column: "packet_type_name") {
      try db.execute("ALTER TABLE decoded_frames ADD COLUMN packet_type_name TEXT")
    }
    if !db.tableHasColumn("decoded_frames", column: "packet_family") {
      try db.execute("ALTER TABLE decoded_frames ADD COLUMN packet_family TEXT")
    }
    try db.execute(
      "CREATE INDEX IF NOT EXISTS idx_decoded_frames_packet_family ON decoded_frames(packet_family)"
    )
  }

  private static func ensureStrapEventsColumns(_ db: GooseDB) throws {
    if !db.tableHasColumn("strap_events", column: "packet_type") {
      try db.execute("ALTER TABLE strap_events ADD COLUMN packet_type INTEGER")
      try db.execute(
        "CREATE INDEX IF NOT EXISTS idx_strap_events_packet_type ON strap_events(packet_type)"
      )
    }
  }

  private static func ensureCommandResponsesColumns(_ db: GooseDB) throws {
    if !db.tableHasColumn("command_responses", column: "packet_type") {
      try db.execute("ALTER TABLE command_responses ADD COLUMN packet_type INTEGER")
      try db.execute(
        "CREATE INDEX IF NOT EXISTS idx_command_responses_packet_type ON command_responses(packet_type)"
      )
    }
  }

  private static func ensureConsoleLogsColumns(_ db: GooseDB) throws {
    if !db.tableHasColumn("console_logs", column: "packet_type") {
      try db.execute("ALTER TABLE console_logs ADD COLUMN packet_type INTEGER")
      try db.execute(
        "CREATE INDEX IF NOT EXISTS idx_console_logs_packet_type ON console_logs(packet_type)"
      )
    }
  }

  private static func ensureAlgorithmDefinitionColumns(_ db: GooseDB) throws {
    let additions: [(String, String)] = [
      ("display_name", "display_name TEXT NOT NULL DEFAULT ''"),
      ("implementation", "implementation TEXT NOT NULL DEFAULT ''"),
      ("license", "license TEXT NOT NULL DEFAULT ''"),
      ("input_requirements_json", "input_requirements_json TEXT NOT NULL DEFAULT '{}'"),
      ("quality_gates_json", "quality_gates_json TEXT NOT NULL DEFAULT '[]'"),
      ("status", "status TEXT NOT NULL DEFAULT 'experimental'"),
    ]
    for (column, ddl) in additions where !db.tableHasColumn("algorithm_definitions", column: column) {
      try db.execute("ALTER TABLE algorithm_definitions ADD COLUMN \(ddl)")
    }
  }

  private static func ensureStepCounterSampleColumns(_ db: GooseDB) throws {
    let additions: [(String, String)] = [
      ("cadence_spm", "cadence_spm REAL"),
      ("activity_state", "activity_state TEXT"),
    ]
    for (column, ddl) in additions where !db.tableHasColumn("step_counter_samples", column: column) {
      try db.execute("ALTER TABLE step_counter_samples ADD COLUMN \(ddl)")
    }
  }

  private static func ensureV24TypedTableColumns(_ db: GooseDB) throws {
    let sleepAdds: [(String, String)] = [
      ("source", "source TEXT NOT NULL DEFAULT 'goose.local'"),
      ("rem_minutes", "rem_minutes INTEGER NOT NULL DEFAULT 0"),
      ("cycle_count", "cycle_count INTEGER NOT NULL DEFAULT 0"),
      ("disturbance_count", "disturbance_count INTEGER NOT NULL DEFAULT 0"),
      ("sleep_need_ms", "sleep_need_ms INTEGER NOT NULL DEFAULT 0"),
      ("date_key", "date_key TEXT NOT NULL DEFAULT ''"),
    ]
    for (column, ddl) in sleepAdds where !db.tableHasColumn("sleep_readings", column: column) {
      try db.execute("ALTER TABLE sleep_readings ADD COLUMN \(ddl)")
    }

    if !db.tableHasColumn("recovery_readings", column: "source") {
      try db.execute(
        "ALTER TABLE recovery_readings ADD COLUMN source TEXT NOT NULL DEFAULT 'goose.local'"
      )
    }

    let strainAdds: [(String, String)] = [
      ("source", "source TEXT NOT NULL DEFAULT 'goose.local'"),
      ("strain_kilojoules", "strain_kilojoules REAL NOT NULL DEFAULT 0"),
    ]
    for (column, ddl) in strainAdds where !db.tableHasColumn("daily_strain_readings", column: column) {
      try db.execute("ALTER TABLE daily_strain_readings ADD COLUMN \(ddl)")
    }

    try db.execute(
      "CREATE INDEX IF NOT EXISTS idx_sleep_readings_date_key ON sleep_readings(date_key)"
    )
  }
}
