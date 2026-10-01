#!/usr/bin/env bash
#
# Tests for docker/trim_metadata.py, the metadata reduction the tool's <command>
# runs before the container is started.
#
# Deliberately plain bash plus the system python3: this is the one piece of the
# packaging that is not R, so it should be testable without an image build.
#
#   bash tests/trim_metadata_test.sh
#
# What matters here is the contract with the application: the trimmer has to
# produce exactly the two column layout the parser expects (sample ids plus one
# condition column), and it has to refuse everything else *without* writing a
# destination file, because the tool then keeps the table it staged and lets the
# application report the problem in its own words.

set -uo pipefail

TRIMMER="${TRIMMER:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/docker/trim_metadata.py}"

if [ ! -f "$TRIMMER" ]; then
    echo "cannot find the trimmer at $TRIMMER" >&2
    exit 1
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

passed=0
failed=0

ok() {
    printf 'ok   %s\n' "$1"
    passed=$((passed + 1))
}

nope() {
    printf 'FAIL %s\n' "$1"
    [ -n "${2:-}" ] && printf '     %s\n' "$2"
    failed=$((failed + 1))
}

check() {
    # check <label> <command...>
    local label="$1"
    shift
    if "$@" > /dev/null 2>&1; then ok "$label"; else nope "$label"; fi
}

# Run the trimmer, capturing its exit code, stderr and the note it leaves for the
# startup log.
run_trim() {
    local src="$1" condition="$2" dst="$3"
    NOTE_FILE="$WORKDIR/note.txt"
    rm -f "$NOTE_FILE" "$dst"
    METADAVIS_TRIM_NOTE_FILE="$NOTE_FILE" python3 "$TRIMMER" \
        "$src" "$condition" "$dst" > "$WORKDIR/out.txt" 2> "$WORKDIR/err.txt"
    TRIM_STATUS=$?
    TRIM_STDERR=$(cat "$WORKDIR/err.txt")
    TRIM_NOTE=$(cat "$NOTE_FILE" 2> /dev/null)
}

# The fixtures are the shapes Galaxy hands over: tab separated tables, comma
# separated tables, CRLF line endings, quoted fields, and tables that are wider
# than the two columns the application can use.
wide_tsv() {
    printf 'SampleID\tSite\tSex\tDepth\n' > "$1"
    printf 'CD.001\tColonoscopy\tFemale\t10\n' >> "$1"
    printf 'CD.002\tClinic\tMale\t20\n' >> "$1"
    printf 'CD.003\tWard\tFemale\t30\n' >> "$1"
}

wide_csv() {
    printf 'SampleID,Site,Sex,Depth\n' > "$1"
    printf 'CD.001,Colonoscopy,Female,10\n' >> "$1"
    printf 'CD.002,Clinic,Male,20\n' >> "$1"
}

echo "== the trimmer reduces a wide table to the sample ids and one condition"
wide_tsv "$WORKDIR/wide.tsv"
run_trim "$WORKDIR/wide.tsv" Site "$WORKDIR/out.tsv"
check "exits cleanly" test "$TRIM_STATUS" -eq 0
check "keeps the header's two column names" \
    test "$(head -n 1 "$WORKDIR/out.tsv")" = "$(printf 'SampleID\tSite')"
check "keeps every sample" test "$(wc -l < "$WORKDIR/out.tsv")" -eq 4
check "keeps the values of the chosen column" \
    grep -qx "$(printf 'CD.002\tClinic')" "$WORKDIR/out.tsv"
check "drops the columns that are not used" \
    bash -c '! grep -q "Female" "$0"' "$WORKDIR/out.tsv"
check "leaves the source alone" \
    bash -c 'test "$(wc -l < "$0")" -eq 4' "$WORKDIR/wide.tsv"
check "reports what it did for the startup log" \
    grep -q "Site" <<< "$TRIM_NOTE"

echo
echo "== the column can be given by name or by number, like Galaxy's data_column"
run_trim "$WORKDIR/wide.tsv" 4 "$WORKDIR/out.tsv"
check "a column number picks that column" \
    test "$(head -n 1 "$WORKDIR/out.tsv")" = "$(printf 'SampleID\tDepth')"
run_trim "$WORKDIR/wide.tsv" " site " "$WORKDIR/out.tsv"
check "a padded name still matches" \
    test "$(head -n 1 "$WORKDIR/out.tsv")" = "$(printf 'SampleID\tSite')"
run_trim "$WORKDIR/wide.tsv" "SITE" "$WORKDIR/out.tsv"
check "matching ignores case" \
    test "$(head -n 1 "$WORKDIR/out.tsv")" = "$(printf 'SampleID\tSite')"
run_trim "$WORKDIR/wide.tsv" "" "$WORKDIR/out.tsv"
check "no choice means the second column" \
    test "$(head -n 1 "$WORKDIR/out.tsv")" = "$(printf 'SampleID\tSite')"

echo
echo "== comma separated tables are detected and trimmed as well"
wide_csv "$WORKDIR/wide.csv"
run_trim "$WORKDIR/wide.csv" Site "$WORKDIR/out.csv"
check "exits cleanly" test "$TRIM_STATUS" -eq 0
check "keeps the comma as the separator" \
    test "$(head -n 1 "$WORKDIR/out.csv")" = "$(printf 'SampleID,Site')"
check "keeps the values" grep -qx "CD.002,Clinic" "$WORKDIR/out.csv"

echo
echo "== quoted fields survive, which is why the csv module is used"
printf 'SampleID,Site,Sex,Depth\n' > "$WORKDIR/quoted.csv"
printf 'CD.001,"Clinic, Main",Female,10\n' >> "$WORKDIR/quoted.csv"
printf 'CD.002,Ward,Male,20\n' >> "$WORKDIR/quoted.csv"
run_trim "$WORKDIR/quoted.csv" Site "$WORKDIR/out.csv"
check "a separator inside a quoted value is not a column break" \
    grep -qx 'CD.001,"Clinic, Main"' "$WORKDIR/out.csv"
check "exits cleanly" test "$TRIM_STATUS" -eq 0

echo
echo "== CRLF line endings do not end up in the values"
printf 'SampleID\tSite\tSex\r\nCD.001\tColonoscopy\tFemale\r\n' > "$WORKDIR/crlf.tsv"
run_trim "$WORKDIR/crlf.tsv" Site "$WORKDIR/out.tsv"
check "exits cleanly" test "$TRIM_STATUS" -eq 0
# The table keeps the line ending style it came with, and the carriage return
# stays where it belongs: at the end of the line, not inside a value. Every line
# ends with one, so as many carriage returns as lines.
check "the line ending style is kept" \
    test "$(tr -cd '\r' < "$WORKDIR/out.tsv" | wc -c)" -eq "$(wc -l < "$WORKDIR/out.tsv")"
check "the values carry no carriage return" \
    grep -qx "$(printf 'CD.001\tColonoscopy\r')" "$WORKDIR/out.tsv"

echo
echo "== a table that is already two columns is left as it is"
printf 'SampleID\tSite\nCD.001\tColonoscopy\n' > "$WORKDIR/pair.tsv"
run_trim "$WORKDIR/pair.tsv" Site "$WORKDIR/out.tsv"
check "exits cleanly" test "$TRIM_STATUS" -eq 0
check "writes no destination file" test ! -e "$WORKDIR/out.tsv"
check "says why nothing was written" \
    grep -q "already has just the sample ids" <<< "$TRIM_NOTE"

echo
echo "== anything that cannot be resolved is refused, not guessed"
wide_tsv "$WORKDIR/wide.tsv"
run_trim "$WORKDIR/wide.tsv" NoSuchColumn "$WORKDIR/out.tsv"
check "an unknown column name fails" test "$TRIM_STATUS" -ne 0
check "an unknown column name explains itself" \
    grep -q "cannot use" <<< "$TRIM_STDERR"
check "an unknown column name writes nothing" test ! -e "$WORKDIR/out.tsv"

run_trim "$WORKDIR/wide.tsv" 99 "$WORKDIR/out.tsv"
check "a number past the last column fails" test "$TRIM_STATUS" -ne 0
check "a number past the last column writes nothing" test ! -e "$WORKDIR/out.tsv"

run_trim "$WORKDIR/wide.tsv" 1 "$WORKDIR/out.tsv"
check "the sample id column is refused" test "$TRIM_STATUS" -ne 0
check "the sample id column writes nothing" test ! -e "$WORKDIR/out.tsv"

run_trim "$WORKDIR/wide.tsv" 0 "$WORKDIR/out.tsv"
check "column zero is refused" test "$TRIM_STATUS" -ne 0

printf 'SampleID\nCD.001\nCD.002\n' > "$WORKDIR/one_column.tsv"
run_trim "$WORKDIR/one_column.tsv" 2 "$WORKDIR/out.tsv"
check "a table without an annotation column fails" test "$TRIM_STATUS" -ne 0
check "a table without an annotation column says so" \
    grep -q "at least one annotation column" <<< "$TRIM_STDERR"
check "a table without an annotation column writes nothing" \
    test ! -e "$WORKDIR/out.tsv"

printf 'SampleID\tSite\tSex\n' > "$WORKDIR/header_only.tsv"
run_trim "$WORKDIR/header_only.tsv" Site "$WORKDIR/out.tsv"
check "a header without samples fails" test "$TRIM_STATUS" -ne 0
check "a header without samples writes nothing" test ! -e "$WORKDIR/out.tsv"

: > "$WORKDIR/empty.tsv"
run_trim "$WORKDIR/empty.tsv" Site "$WORKDIR/out.tsv"
check "an empty file fails" test "$TRIM_STATUS" -ne 0
check "an empty file writes nothing" test ! -e "$WORKDIR/out.tsv"

echo
echo "== a short row does not take the reduction down"
printf 'SampleID\tSite\tSex\nCD.001\tColonoscopy\tFemale\nCD.002\n' > "$WORKDIR/ragged.tsv"
run_trim "$WORKDIR/ragged.tsv" Site "$WORKDIR/out.tsv"
check "exits cleanly" test "$TRIM_STATUS" -eq 0
check "the short row gets an empty condition" \
    grep -qx "$(printf 'CD.002\t')" "$WORKDIR/out.tsv"

echo
if [ "$failed" -ne 0 ]; then
    echo "$failed of $((passed + failed)) metadata trimming checks failed"
    exit 1
fi
echo "all $passed metadata trimming checks passed"