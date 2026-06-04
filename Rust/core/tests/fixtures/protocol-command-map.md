# Protocol command map (snapshot)

Snapshot of every command ID `goose-core` currently models. Loaded by
`command_definitions_cover_generated_protocol_command_map_ids` in
`tests/command_tests.rs` to guard against accidental removal of a command
from `COMMAND_DEFINITIONS`.

The original upstream generator that produced
`docs/generated/protocol-command-map.md` is gone; this snapshot replaces
it. If you intentionally remove a command, delete its row here too.
If you add a new command, add a row here so the next regression keeps
catching drops.

| ID | Name |
|----|------|
| 1   | link_valid |
| 2   | get_max_protocol_version |
| 3   | toggle_realtime_hr |
| 7   | report_version_info |
| 10  | set_clock |
| 11  | get_clock |
| 14  | toggle_generic_hr_profile |
| 16  | toggle_r7_data_collection |
| 19  | run_haptic_pattern_maverick |
| 20  | abort_historical_transmits |
| 22  | send_historical_data |
| 23  | historical_data_result |
| 25  | force_trim |
| 26  | get_battery_level |
| 29  | reboot_strap |
| 32  | power_cycle_strap |
| 33  | set_read_pointer |
| 34  | get_data_range |
| 35  | get_hello_harvard |
| 36  | start_firmware_load |
| 37  | load_firmware_data |
| 38  | process_firmware_image |
| 39  | set_led_drive |
| 40  | get_led_drive |
| 41  | set_tia_gain |
| 42  | get_tia_gain |
| 43  | set_bias_offset |
| 44  | get_bias_offset |
| 45  | enter_ble_dfu |
| 52  | set_dp_type |
| 53  | force_dp_type |
| 63  | send_r10_r11_realtime |
| 66  | set_alarm_time |
| 67  | get_alarm_time |
| 68  | run_alarm |
| 69  | disable_alarm |
| 76  | get_advertising_name_harvard |
| 77  | set_advertising_name_harvard |
| 79  | run_haptics_pattern |
| 80  | get_all_haptics_pattern |
| 81  | start_raw_data |
| 82  | stop_raw_data |
| 83  | verify_firmware_image |
| 84  | get_body_location_and_status |
| 96  | enter_high_freq_sync |
| 97  | exit_high_freq_sync |
| 98  | get_extended_battery_info |
| 105 | toggle_imu_mode_historical |
| 106 | toggle_imu_mode |
| 107 | enable_optical_data |
| 108 | toggle_optical_mode |
| 115 | start_device_config_key_exchange |
| 116 | send_next_device_config |
| 117 | start_feature_flag_key_exchange |
| 118 | send_next_feature_flag |
| 119 | set_device_config_value |
| 120 | set_feature_flag_value |
| 121 | get_device_config_value |
| 122 | stop_haptics |
| 123 | select_wrist |
| 124 | toggle_labrador_data_generation |
| 125 | toggle_labrador_raw_save |
| 128 | get_feature_flag_value |
| 131 | set_research_packet |
| 132 | get_research_packet |
| 139 | toggle_labrador_filtered |
| 140 | set_advertising_name |
| 141 | get_advertising_name |
| 142 | start_firmware_load_new |
| 143 | load_firmware_data_new |
| 144 | process_firmware_image_new |
| 145 | get_hello |
| 151 | get_battery_pack_info |
| 153 | toggle_persistent_r20 |
| 154 | toggle_persistent_r21 |
