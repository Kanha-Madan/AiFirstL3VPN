# Writing Custom Keywords

> How to extend CXTA with custom Python keyword libraries and composed Robot keywords.

---

## Python Keyword Libraries

### Class Structure

Custom keyword classes **must** inherit from `CXTA.robot.Shared` and the **class name must match the filename** (e.g., `Math.py` → `class Math`).

```python
from CXTA.robot import Shared
from robot.api.deco import keyword

class Math(Shared):
    """Custom math operations for testing."""

    @keyword(r'add (\d+) and (\d+)')
    def add(self, a, b):
        """Adds two numbers."""
        return int(a) + int(b)
```

### The `@keyword` Decorator

- Pattern uses regex syntax: `r'pattern "${arg1}" something "${arg2}"'`
- Arguments captured by `"${...}"` groups map to method parameters in order
- The decorator registers the keyword pattern with Robot Framework

### Using `Shared` Base Class

Inheriting from `Shared` provides access to:
- `self.testbed` — the pyATS testbed object
- `self.devices` — connected device objects
- `self.logger` — standard Python logger
- All state shared across CXTA keyword libraries

### Loading Custom Libraries

Place the Python file in the test directory and add it to `*** Settings ***`:

```robot
*** Settings ***
Library    CXTA
Resource   cxta.robot
Library    ./Math.py
```

Or use a path relative to the test execution directory.

---

## Robot Framework Keywords

Compose existing keywords into higher-level abstractions in the `*** Keywords ***` section.

### Basic Custom Keyword

```robot
*** Keywords ***
setup-nso
    use testbed "testbed.yaml"
    connect to device "nso"
    ${output}=    execute command "devices fetch-ssh-host-keys" on device "nso"
    Should not contain    ${output}    result false
    ${output}=    execute command "devices sync-from" on device "nso"
    Should not contain    ${output}    result false
```

### Keyword with Embedded Arguments

Use `${variable}` in the keyword name for embedded arguments (CXTA style):

```robot
*** Keywords ***
collect "${state}" config from "${device}"
    connect to device "${device}"
    ${output}=    execute command "show running-config" on device "${device}"
    Create File    ${device}-${state}.txt    ${output}

compare configs from "${device}" and compare with "${expected_diffs}"
    use ciscoconfdiff to compare ios configs "${device}-before.txt" and "${device}-after.txt"
    compare latest ciscoconfdiff with reference diffs in "@{expected_diffs}[0]" and "@{expected_diffs}[1]"
```

### Keyword with Tabular Arguments

Standard Robot Framework `[Arguments]` syntax:

```robot
*** Keywords ***
Verify Service On Device
    [Arguments]    ${device}    ${interface}    ${expected_ip}
    connect to device "${device}"
    ${output}=    execute command "show ip interface brief" on device "${device}"
    Should Contain    ${output}    ${interface}
    Should Contain    ${output}    ${expected_ip}
```

---

## Guidelines

1. **Prefer embedded arguments** (CXTA style) for keywords used in test cases — they read like natural language
2. **Prefer tabular arguments** for utility keywords called from other keywords
3. **Keep keyword scope small** — each keyword does one logical thing
4. **Name keywords descriptively** — the keyword name should explain what it does
5. **Use Suite Setup/Teardown** for connection management, test-level setup/teardown for rollback management
