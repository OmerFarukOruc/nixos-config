# Reject limits outside 1 through 100

Readiness: DRAFT
Revision: 1
Repository: teaching fixture `limit.py` and `test_limit.py` at `<fixture-sha>` on `main`, a git repository with one commit; local changes: none
Landing: none, because no PR, push, or deploy is part of this teaching example (Out of scope)

## Outcome

`parse_limit` returns any integer a caller passes, so a request for 0 or 500 items reaches the code that trusts the limit. After the change it returns an integer from 1 through 100 or raises `ValueError`. The default of 25 for `None`, integer conversion, whitespace handling, and the `ValueError` for non-numeric text stay unchanged.

Bounds: callers are other Python modules in the same process; no operator; the function holds no state, so concurrent calls share nothing; a rejected limit is a caller error, and a wrong limit that passes is the failure this plan removes.

## Sources

- in-repo only: `limit.py`, `test_limit.py`; imports checked: `unittest` (standard library), no third-party surface

## Current state

- `limit.py::parse_limit`: the only parser; returns `25` for `None`, otherwise `int(raw)` with no range check, and the module has a one-line docstring.
- `test_limit.py::ParseLimitTests`: the existing coverage and the contract's owner test; three tests: `test_default`, `test_valid`, `test_not_numeric`.
- Testing policy: the fixture has no `AGENTS.md`, `CLAUDE.md`, or testing document, so nothing requires a new test; the proof is a caller run, and the existing tests are the gate.
- Terms: limit means the page size a caller asks for. `<fixture-sha>` means the full SHA that `git rev-parse main` prints in the fixture before any change; a teaching fixture is rebuilt for each reader, so its SHA differs per copy.

## Decisions

- Keep `int(raw)` as the single conversion and check the bounds on its result, so conversion failures and whitespace handling stay exactly as they are.
- The error is `ValueError("limit must be between 1 and 100")`, raised after conversion; callers already catch `ValueError` for bad text, so no new exception type. Its message differs from the one `int()` raises, so the caller run shows which guard rejected an input.
- The signature `parse_limit(raw: str | None) -> int` stays, so no caller changes.
- Out of scope: any configuration for the bounds, any caller change; there are no callers beyond the tests.

## Commands

| Purpose | Command (the standard library; the fixture has no command file) | Expected |
| --- | --- | --- |
| Install | none; the fixture imports only the standard library | nothing to run |
| Caller run | the bash command below, from the fixture root | one line per input, as Red and Green below |
| Gate | `python3 -m unittest -v` from the fixture root | exit 0, `Ran 3 tests`, `OK` |

Caller run:

```bash
for r in 1 100 " 7 " 0 -1 101 99999999999 1.5 nope; do python3 -c 'import sys; from limit import parse_limit; print(repr(sys.argv[1]), parse_limit(sys.argv[1]))' "$r" 2>&1 | tail -n 1; done
```

## Slices

### 1. Reject out-of-range values while preserving parsing

Blocked by: none
Commit: `fix: reject limits outside 1 through 100`
Operator: none
Touch set: `limit.py`
Interface: none
Behavior:

- `"1"` returns 1, `"100"` returns 100, `" 7 "` returns 7.
- `"0"`, `"-1"`, `"101"`, and `"99999999999"` raise `ValueError` whose message is `limit must be between 1 and 100`.
- `"1.5"` and `"nope"` raise the `ValueError` that `int()` raises, and `None` returns 25; the Caller run shows the first two, and the existing `test_default` covers `None`.

Red: the Caller run drives the nine string inputs above; at `<fixture-sha>` it prints `'1' 1`, `'100' 100`, `' 7 ' 7`, `'0' 0`, `'-1' -1`, `'101' 101`, `'99999999999' 99999999999`, then `ValueError: invalid literal for int() with base 10: '1.5'` and `ValueError: invalid literal for int() with base 10: 'nope'`, copied from a run of the fixture
Change:

1. From the fixture root, run `git diff --stat <fixture-sha> -- limit.py test_limit.py` and `git status --short -- limit.py test_limit.py`; both print nothing.
2. Run the Caller run; it prints the Red output above.
3. Replace only the body of `limit.py::parse_limit`. Keep the signature and the module docstring. Keep `int(raw)` as the conversion. After conversion, reject values outside 1 through 100 with this TARGET:

   ```python
   raise ValueError("limit must be between 1 and 100")
   ```

4. Run the Gate; it exits 0 and prints `Ran 3 tests` and `OK`.
5. Run `git commit -m "fix: reject limits outside 1 through 100" -- limit.py`; then `git status --short -- limit.py test_limit.py` prints nothing.

Green: the Caller run prints `'1' 1`, `'100' 100`, `' 7 ' 7`, then `ValueError: limit must be between 1 and 100` four times, then `ValueError: invalid literal for int() with base 10: '1.5'` and `ValueError: invalid literal for int() with base 10: 'nope'`, copied from a run of the fixture with the change committed
Done when: Green and the Gate are observed, and `git show --stat --format=%s HEAD` prints the Commit subject and `limit.py | 5 ++++-`.

## Final gate

1. The Caller run prints the Green output, and the Gate exits 0 with `Ran 3 tests` and `OK`.
2. `git diff --name-only <fixture-sha> HEAD` prints only `limit.py`, and `grep -c 'def parse_limit(raw: str | None) -> int:' limit.py` prints `1`.

No PR, push, or deploy is part of this teaching example.

## Stop conditions

- The drift check in Change step 1 prints a path, or a Current state fact line is false: `parse_limit` already checks a range, or the test class has more than three tests.
- The Red run prints other output than the Red line, for example an import error.
- A change needs a second file.
- Two sections of this plan disagree, such as a Behavior line and the Green line.
- Green or the Gate still differs from its expected output after one edit to `limit.py`.

On a stop, change nothing more and report in this shape:

```text
Stop: <the stop condition, quoted>
Expected: <the plan text the run tested>
Found: <what the run or the code shows>
Evidence: <the command and its output>
```

## Residual

none

## Open decisions

none
