# Device CLI Keywords Reference

> Keywords from **DeviceCli.py** for executing commands, monitoring output, and managing device connections.

---

## Connection Keywords

#### `connect to device "${device}"`
Opens a connection to the device using the default connection defined in testbed (`defaults.via`).

#### `connect to device "${device}" via "${connection}"`
Opens a specific connection type (e.g., `cli`, `rest`, `netconf`).

#### `connect to device "${device}" as alias "${alias}"`
Opens a connection with a named alias for managing multiple sessions.

#### `connect to device "${device}" via "${connection}" as alias "${alias}"`
Combines connection type and alias.

#### `connect to device "${device}" trying all available connections`
Attempts all connections defined in testbed until one succeeds.

#### `connect to devices "${devices}"`
Connects to semicolon-separated devices: `connect to devices "r1;r2;r3"`.

#### `disconnect from device "${device}"`
Closes the connection to the device.

---

## Command Execution

#### `execute command "${command}" on device "${device}"`
Executes a command and returns the output. **Most commonly used keyword.**

```robot
${output}=    execute command "show running-config" on device "pe1"
```

#### `execute "${command}" on device "${device}"`
Shorthand for above.

#### `execute command "${command}" on device "${device}" using alias "${alias}"`
Target a specific connection alias.

#### `execute command "${command}" on devices "${devices}"`
Run the same command on multiple semicolon-separated devices. Returns concatenated output.

#### `execute commands from file "${file}" on device "${device}"`
Reads commands from a text file (one per line) and executes each sequentially.

#### `run "${command}"`
Runs a command on the currently selected device.

#### `execute "${command}"`
Runs on current device (must use `select device` first).

#### `run "${command}" on "${device}"`
Shorthand for execute on a specific device.

---

## Device Selection

#### `select device "${device}"`
Sets the "current device" for subsequent `run`, `execute`, `configure` keywords that don't specify a device.

#### `select device "${device}" using alias "${alias}"`
Sets both device and specific connection alias.

#### `get current device`
Returns the name of the currently selected device.

---

## Configuration Mode

#### `configure`
Enters configuration mode on the current device (requires `select device` first). Uses `**kwargs` for flexibility.

---

## Interactive Commands

#### `run "${command}" and sendline "${response}" to prompt matching pattern "${prompt}"`
Runs a command, waits for a prompt matching the regex pattern, then sends the response followed by newline.

#### `run "${command}" and send "${response}" to prompt matching pattern "${prompt}"`
Same but sends without newline.

#### `execute command "${command}" on device "${device}" with dialog "${dialog}"`
Handles interactive commands using Unicon Dialog objects.

#### `sendline "${command}"`
Sends a command with newline to the current device without waiting for output.

#### `sendline "${command}" to device "${device}"`
Sends to a specific device.

#### `send "${command}"`
Sends without newline to the current device.

---

## Output Capture

#### `store command "${command}" from device "${device}" in file "${filename}"`
Executes command and writes output to a file with timestamp.

#### `store command "${command}" from device "${device}" as "${variable}"`
Stores command output in a Robot variable for later reference.

#### `check if command "${command}" matches regex "${regex}"`
Runs a command on the current device and checks if output matches a regex pattern.

#### `check command "${command}" from device "${device}" for regex "${regex}"`
Same but specifies the device explicitly.

---

## Monitoring

Poll a command repeatedly until a condition is met or timeout.

#### `monitor command "${command}" on device "${device}" until output contains "${expected}"`
Polls until output contains the expected string.

#### `monitor command "${command}" on device "${device}" until output contains "${good}" or "${bad}" within "${timeout}" seconds`
Polls with both positive and negative conditions plus explicit timeout.

#### `monitor command "${command}" on device "${device}" until output matches pattern "${good}" or "${bad}" within "${timeout}" seconds`
Same but uses regex matching instead of substring.

#### `monitor command "${command}" on device "${device}" until output does not contain "${expected}" or "${bad}" within "${timeout}" seconds`
Waits for text to disappear from output.

#### `monitor command "${command}" until output contains "${expected}" or "${bad}" within "${timeout}" seconds`
Operates on current device.

#### `monitor command "${command}" until output matches pattern "${expected}" or "${bad}" within "${timeout}" seconds`
Regex version on current device.

---

## Timeouts and Intervals

#### `set timeout "${time}"`
Sets the command execution timeout. Default varies by platform.

#### `set connection timeout "${time}"`
Sets the device connection timeout.

#### `set monitor interval to "${interval}" seconds`
Sets polling interval for monitoring keywords. Default: 5 seconds.

#### `set monitor timeout to "${timeout}" seconds`
Sets overall monitoring timeout. Default: 300 seconds.

---

## CLI Style

#### `set cli style to "${style}" on device "${device}"`
Switches CLI style (e.g., Cisco/Juniper) on a device. Useful for NSO or NX-OS.
