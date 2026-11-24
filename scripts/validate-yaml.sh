#!/usr/bin/env bash
# Parse every given YAML file. Exits non-zero, naming each file that is
# missing, empty, does not parse, or holds more than one YAML document. Uses ruby (present on GitHub runners
# and macOS) so no extra install is needed.
set -uo pipefail
[[ $# -gt 0 ]] || { echo "usage: validate-yaml.sh file..." >&2; exit 2; }
bad=0
for f in "$@"; do
  if [[ ! -s "$f" ]]; then
    echo "FAIL $f: missing or empty"; bad=1; continue
  fi
  if err=$(ruby -ryaml -e 'n = Psych.parse_stream(File.read(ARGV[0])).children.size; abort("empty") if n == 0; abort("#{n} YAML documents; expected exactly 1") if n > 1' "$f" 2>&1); then
    echo "ok   $f"
  else
    echo "FAIL $f: $(echo "$err" | head -1)"; bad=1
  fi
done
exit "$bad"
