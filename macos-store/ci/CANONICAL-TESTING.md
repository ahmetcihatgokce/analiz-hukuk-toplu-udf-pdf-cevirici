# Canonical UDF comparison scope

`generate-canonical.js` creates original synthetic text, styles, tab stops,
tables, a red image, page breaks, headers/footers and a 160-paragraph document.
It serializes these through the installed official UYAP public document writer
and editor actions. No client document, UYAP implementation or runtime is
included in the application.

Run this on disposable Mac CI before introducing distribution credentials:

1. Run the original official UYAP probe to set `UYAP_TEST_JAVA` and
   `UYAP_TEST_CLASSPATH`.
2. Run `generate-canonical.js` using that runtime's Nashorn shell.
3. Run `prepare-canonical-comparison.py --canonical GENERATED --output STAGED`.
   It requires all eight official-serialized positive cases and adds only the
   separately identified JDOM emoji rejection regression.
4. Run `compare-official.py --fixtures STAGED` with the existing app/runtime,
   sandbox working root, bridge-source and report arguments.

The gate preserves strict comparisons of page count, page dimensions,
normalized text, phrase occurrences, font styles/sizes, visible ink geometry
and colored-area geometry. The default geometric tolerance remains three PDF
points. An unsafe or unavailable ink isolation is a failure.

The old handwritten `native-fixtures.py` cases and Swift model tests exercise
bounded parser contracts, malformed data and rejection paths. They are not the
official output fidelity corpus. In particular, a handwritten empty top-level
page-break was not recognized by UYAP and cannot serve as a golden reference.
The official editor action emits a page-break branch containing its consumed
newline paragraph.

The official UYAP 5.4.21 JDOM 0.9 parser rejects a supplementary emoji character's
high surrogate (`0xd83d`). That case remains a separate oracle-negative check;
it does not count as validated compatibility. Native UTF16 safety tests continue
to preserve supplementary characters independently.

Passing these synthetic cases is evidence for the tested features, not a claim
that arbitrary UDF templates, signature validation, tracked changes, fields or
all real-world document layouts are supported.
