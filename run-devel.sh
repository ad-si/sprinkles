#!/bin/bash

# Convenience script for interactive-ish development. Starts up some background
# processes to constantly update and restart things.
#
# Specifically:
# - Recompile on source change
# - Restart servers on relevant changes
# - Re-run tests on source change
# - Rebuild haddock on source change
# - Rebuild tags file on source change

function watch_serve() {
    BASEDIR="$(realpath .)"
    cd "$1"
    for ((;;))
    do
        templar "$2" &
        PID="$!"
        inotifywait \
            -e modify \
            -e attrib \
            "$(which templar)" \
            project.yml \
            templates/** \
            $(find -name static) \
            "$BASEDIR"/run-devel.sh || exit 255
        kill "$!"
    done
}

function watch_hasktags() {
    for ((;;))
    do
        inotifywait \
            -e modify \
            -e attrib \
            src/**/*.hs app/*.hs test
        hasktags . -c
    done
}

stack install # --test --haddock
watch_serve examples/blogg 6000 &
watch_serve examples/countryInfo 6001 &
watch_hasktags &
stack install --file-watch # --test --haddock
