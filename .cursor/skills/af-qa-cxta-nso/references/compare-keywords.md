# Compare Keywords Reference

> Keywords from **Compare.py** for comparing device configurations, JSON, XML, and text.

---

## Configuration Comparison

#### `diff config of device "${device}"`
Shows a unified diff of the device's running config between the last two stored snapshots. Must have previously executed a show command and stored the output.

```robot
# Capture before
execute command "show running-config" on device "pe1"
# ... make changes ...
# Capture after
execute command "show running-config" on device "pe1"
# Diff
diff config of device "pe1"
```

#### `compare config of device "${device}"`
Compares the last two stored config snapshots. Fails the test if differences are found. Returns a list of differences.

```robot
@{diffs}=    compare config of device "pe1"
```

#### `compare latest config diff of device "${device}"`
Like `compare config` but only compares the most recent two snapshots. Fails if differences exist.

---

## Tree-Based Comparison

#### `treecompare config of device "${device}"`
Hierarchical tree-based comparison of device configurations. Understands configuration structure (parent/child relationships). More accurate than line-by-line diff for structured configs.

---

## CiscoConfDiff Comparison

#### `ciscoconfdiff config of device "${device}"`
Uses CiscoConfDiff algorithm for comparing Cisco-style configurations. Understands section boundaries and indentation hierarchy.

#### `ciscoconfdiff latest config diff of device "${device}"`
CiscoConfDiff on only the latest two snapshots.

---

## Data Format Comparison

#### `compare JSON "${json_a}" to "${json_b}"`
Compares two JSON strings. Normalizes and does structural comparison. Fails if different.

#### `compare XML "${xml_a}" to "${xml_b}"`
Compares two XML strings. Does structural comparison ignoring formatting differences. Fails if different.

#### `compare text "${text_a}" to "${text_b}"`
Simple text diff comparison. Fails if different.

---

## Regex Replacement

#### `match and replace "${input}" matching "${regex}" with "${replacement}"`
Applies regex substitution to a string. Useful for normalizing dynamic values before comparison.

```robot
${normalized}=    match and replace "${output}" matching "\\d{4}-\\d{2}-\\d{2}" with "DATE"
```

---

## Exception Control

#### `disable compare exception`
Prevents compare keywords from failing the test when differences are found. Diffs are still logged.

```robot
disable compare exception
compare config of device "pe1"    # Will log but not fail
enable compare exception
```

#### `enable compare exception`
Re-enables test failure on comparison differences (default behavior).

---

## Typical Comparison Workflow

```robot
*** Test Cases ***
Verify Service Does Not Affect Running Config
    [Setup]    connect to device "pe1"
    
    # Snapshot BEFORE
    execute command "show running-config" on device "pe1"
    
    # Apply service
    via NSO REST API configure "/api/running/services/my-service" on device "${nso}" with payload from file "service.xml"
    
    # Snapshot AFTER
    execute command "show running-config" on device "pe1"
    
    # Compare — fails if config changed
    compare config of device "pe1"
    
    [Teardown]    disconnect from device "pe1"
```
