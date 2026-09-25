#!/bin/bash
# Run every test in this directory.
#
# This file exists because the list of tests was prose. The README named
# tests/test-classifiers.sh and nothing else, while three other suites had
# been added around it — test-pr-resolution.sh, test-qwenpaw-command.py and
# test-description-literals.sh. Two of them were written to catch a specific
# regression and then had no path by which anyone would run them, which is the
# same as not having written them. A list that is also the runner cannot drift
# from what exists; a list in a README can and did.
#
# Adding a suite means adding a line here. The README points at this file
# rather than repeating the names.
#
# run-gold-set.py is deliberately absent: it calls a paid classifier and needs
# a key, so it is not part of an unattended run. Its invocation is documented
# in the README section on the Jev shadow classifier.
set -u

cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
for t in \
  tests/test-classifiers.sh \
  tests/test-pr-resolution.sh \
  tests/test-description-literals.sh \
  tests/test-qwenpaw-command.py
do
  printf '\n── %s\n' "$t"
  case "$t" in
    *.py) python3 "$t" ;;
    *)    bash "$t" ;;
  esac || fail=1
done

printf '\n'
if [ "$fail" -eq 0 ]; then
  echo "all suites passed"
else
  echo "at least one suite failed"
fi
exit "$fail"
