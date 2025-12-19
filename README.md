
`use-json` (or `ujson`) is a library for extracting data from JSON.

**Features:**

- It supports JSON documents with unlimited nesting depth.
- It can read numbers with arbitrary precision.
- It allows trailing commas and single-line comments.
- It doesn't panic on out-of-memory errors.
- It can detect which JSON fields were actually used by your code.
  As a result, when a new version of a JSON document introduces additional fields,
  you can easily identify fields that are not yet handled by your code.

**Limitations:**

- The entire JSON document must fit into memory.
- During parsing, the input data are mutated in place; even if parsing fails,
  the data may no longer be valid JSON.
- Fields cannot be used more than once
  (in my experience, this was usually a sign of a mistake made while copy-pasting code).

## Usage

Copy libraries `btree.c3l` and `ujson.c3l` to you project.
Then compile your project with those libraries.

## Contributions

We accept:

- ✅ Bug reports for the following platforms:
    - macOS on arm64
    - Windows 11 on x64
    - Linux on x64

We don't accept:

- ❌ Pull requests
- ❌ Feature requests
