# orchclaude template: Python Script

Build a polished Python CLI script in this directory.

## Project Goal

Create a command-line Python script that solves a real, self-contained problem.
Look for context clues in this directory (existing files, a README, a task description)
to decide what the script should do. If no context is found, build a **file organizer**
that sorts files in a target directory by extension into named subfolders.

## CLI interface requirements

Use `argparse` to define the interface. The script must support:

- A clear primary positional or required argument (the main input)
- At least two optional flags that modify behavior (e.g. `--dry-run`, `--verbose`, `--output`)
- `--help` that prints a useful description of every argument
- `--version` that prints the script version

## Code quality requirements

- **Python 3.9+** compatible; no third-party dependencies unless unavoidable
- If third-party packages are needed, list them in `requirements.txt`
- Typed function signatures (`def process(path: Path) -> list[str]:`)
- Docstrings on every public function (one-line summary is enough)
- All errors caught and reported as `Error: <message>` to stderr, then `sys.exit(1)`
- No bare `except:` clauses
- `if __name__ == "__main__":` guard

## Deliverables

1. `main.py` (or a descriptive name matching the script's purpose)
2. `requirements.txt` (may be empty if stdlib-only)
3. `README.md` with:
   - What the script does
   - Install instructions (`pip install -r requirements.txt` if needed)
   - Full usage with all flags documented
   - At least three example invocations

## Acceptance

Run the script and verify:
- `python main.py --help` outputs a clear help message
- The primary function works correctly on a sample input
- `--dry-run` (or equivalent) does not make permanent changes
- Bad input produces an informative error message and exits with code 1

When done, output: ORCHESTRATION_COMPLETE
