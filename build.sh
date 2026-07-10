#!/usr/bin/env bash
# Stamps the deploying commit's short SHA into index.html's version line.
# Vercel runs this via vercel.json's buildCommand.
#
# Guards both ends of the substitution: the placeholder must exist before
# (so it can't be quietly deleted) and must be gone after (so a failed
# substitution can't ship a frozen version string).
set -euo pipefail

FILE=index.html
MARKER=__COMMIT__

if ! grep -q "$MARKER" "$FILE"; then
  echo "build stamp: $MARKER placeholder is missing from $FILE" >&2
  exit 1
fi

# Empty when git integration is off; "dev" then makes that visible in the page.
SHA=$(printf %s "${VERCEL_GIT_COMMIT_SHA:-dev}" | cut -c1-7)

# Not `sed -i`: BSD and GNU sed disagree on whether it takes an argument.
sed "s/$MARKER/$SHA/g" "$FILE" > "$FILE.stamped"
mv "$FILE.stamped" "$FILE"

if grep -q "$MARKER" "$FILE"; then
  echo "build stamp: substitution failed" >&2
  exit 1
fi

echo "build stamp: $SHA"
