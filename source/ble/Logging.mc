import Toybox.Lang;

// BLE logging on or off at compile time. Log calls are written as "if (BLE_LOGGING) { log(...); }":
// with -O 3, a false constant drops the whole call and its message strings from the program,
// which is ~2 KB of the data field's 32 KB (measured in the simulator). The jungle picks one of
// the two definitions with excludeAnnotations; build.ps1 -Lean and -Release build without logs.
(:ble_log)
const BLE_LOGGING = true;

(:ble_nolog)
const BLE_LOGGING = false;
