#!/bin/sh
# Xcode Cloud supplies the signing team; never store account identifiers in Git.
set -eu
: "${CI_PRIMARY_REPOSITORY_PATH:?Xcode Cloud repository path is required}"
: "${CI_TEAM_ID:?Xcode Cloud signing team is required}"
case "$CI_TEAM_ID" in
    *[!A-Z0-9]*) echo 'Invalid signing team format.' >&2; exit 1 ;;
esac
if [ "${#CI_TEAM_ID}" -ne 10 ]; then
    echo 'Invalid signing team format.' >&2
    exit 1
fi
umask 077
printf 'DEVELOPMENT_TEAM = %s\n' "$CI_TEAM_ID" > "$CI_PRIMARY_REPOSITORY_PATH/Configuration/LocalSigning.xcconfig"
