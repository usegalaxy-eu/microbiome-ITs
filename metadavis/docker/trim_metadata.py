#!/usr/bin/env python3
"""Reduce a sample metadata table to the two columns MetaDAVis can use.

The application only ever works with two metadata columns: the sample ids and
the grouping condition. Every plot reads the second column of the metadata
table as the condition and the summary tables are built from the first two
columns, so any further annotation column of a wide table is dead weight - and
worse, the parser cannot handle one: it reads the file a second time and
renames *all* of its columns to "Condition", which fails as soon as there is
more than the one column the plots look at.

So this runs in the tool's <command>, before the container is started, and
writes the reduced table the application is pointed at. Which of the
annotation columns is the condition is decided by the tool form (a
``data_column`` param), either as a column name or as a column number; without
a choice the second column is used, which is the layout the application has
always been fed by hand.

Everything the parser cannot cope with is left alone: on any problem this
exits non-zero without a destination file, and the caller keeps the staged
table. That way a bad column selection can never turn into an empty analysis,
only into the application's own error message.

The table is parsed with the csv module rather than by splitting on the
separator, so quoted fields - a sample called "Clinic, Main", or a whole
quoted CSV file - survive the reduction instead of being cut into pieces.
"""

from __future__ import annotations

import csv
import os
import sys

# Splitting on any of these is what the R parser ends up doing (read.table and
# read.delim both sniff the separator of the file they are given), so they are
# the candidates here as well.
CANDIDATE_DELIMITERS = ",\t;"


def die(message: str, code: int = 3) -> None:
    """Report a reason on stderr and exit, leaving no destination file behind."""
    sys.stderr.write("metadavis-trim-metadata: %s\n" % message)
    sys.exit(code)


def read_table(path: str) -> tuple[list[str], list[list[str]], str, str]:
    """Return the header, the data rows, the delimiter and the line terminator."""
    with open(path, "r", encoding="utf-8-sig", newline="") as handle:
        sample = handle.read(65536)
        if not sample.strip():
            die("%s is empty" % path, code=2)
        handle.seek(0)
        try:
            delimiter = csv.Sniffer().sniff(sample, delimiters=CANDIDATE_DELIMITERS).delimiter
        except csv.Error:
            # Sniffer needs a couple of consistent lines, which a one row table
            # (header plus a single sample) does not give it. Fall back to
            # counting, where the separator occurring more often in the header
            # wins - the same rule the R parser uses.
            counts = {candidate: sample.splitlines()[0].count(candidate) for candidate in CANDIDATE_DELIMITERS}
            delimiter = max(counts, key=counts.get)
            if counts[delimiter] == 0:
                delimiter = "\t"
        rows = [row for row in csv.reader(handle, delimiter=delimiter) if any(field.strip() for field in row)]
    if not rows:
        die("%s has no header line" % path, code=2)
    # The csv module writes CRLF by default, which would rewrite every line of a
    # unix table. Keep whatever the table it was read from uses.
    terminator = "\r\n" if "\r\n" in sample else "\n"
    return rows[0], rows[1:], delimiter, terminator


def clean(name: str) -> str:
    """Reduce a column name to what can be compared.

    Galaxy hands the header over the way its own parser saw it, which can
    differ from what the csv module produced: surrounding quotes, a stray
    carriage return, a different case or padding.
    """
    return name.replace("\r", "").strip().strip('"').strip().lower()


def resolve_column(picked: str, header: list[str]) -> int:
    """Return the 1-based index of the annotation column to use."""
    if not header or len(header) < 2:
        die(
            "the metadata table needs a sample column and at least one annotation column, "
            "it has %d column(s)" % len(header),
            code=2,
        )

    wanted = (picked or "").strip()
    if not wanted:
        return 2

    if wanted.isdigit():
        index = int(wanted)
    else:
        index = 0
        for position, name in enumerate(header, start=1):
            if clean(name) == clean(wanted):
                index = position
                break

    # Column 1 holds the sample ids, so it can never be the condition.
    if index < 2 or index > len(header):
        die(
            'cannot use "%s" as the grouping condition: the metadata table has %d column(s), '
            "pick one of 2 to %d" % (wanted, len(header), len(header))
        )
    return index


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        die("usage: metadavis-trim-metadata <metadata> <condition> <destination>")
    source, picked, destination = argv[1:4]

    header, rows, delimiter, terminator = read_table(source)
    index = resolve_column(picked, header)

    if len(header) == 2:
        # Already the layout the application expects - leave the staged file
        # untouched rather than rewriting it.
        note = "the metadata table already has just the sample ids and one condition column"
        if os.environ.get("METADAVIS_TRIM_NOTE_FILE"):
            write_note(os.environ["METADAVIS_TRIM_NOTE_FILE"], note)
        print(note)
        return 0

    # An empty result would silently drop every sample, so treat it as a failure
    # rather than handing the application a table without samples.
    if not rows:
        die("%s has no data rows below its header" % source, code=2)

    partial = os.path.dirname(destination)
    if partial:
        os.makedirs(partial, exist_ok=True)
    with open(destination, "w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(
            handle, delimiter=delimiter, quoting=csv.QUOTE_MINIMAL, lineterminator=terminator
        )
        writer.writerow([header[0].replace("\r", ""), header[index - 1].replace("\r", "")])
        for row in rows:
            sample_id = row[0].replace("\r", "") if row else ""
            condition = row[index - 1].replace("\r", "") if index <= len(row) else ""
            writer.writerow([sample_id, condition])

    note = "reduced the metadata table to the sample ids and '%s' (%d samples, %d of %d columns)" % (
        header[index - 1].replace("\r", ""),
        len(rows),
        2,
        len(header),
    )
    if os.environ.get("METADAVIS_TRIM_NOTE_FILE"):
        write_note(os.environ["METADAVIS_TRIM_NOTE_FILE"], note)
    print(note)
    return 0


def write_note(path: str, note: str) -> None:
    """Hand the one line summary to the entry point, which writes the startup log."""
    try:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(note + "\n")
    except OSError:
        # A missing note is not worth failing a job over.
        pass


if __name__ == "__main__":
    sys.exit(main(sys.argv))