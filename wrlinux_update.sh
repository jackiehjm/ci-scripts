#!/bin/bash

# Copyright (c) 2017 Wind River Systems Inc.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

if [ -z "$BASE" ]; then
    BASE=/home/wrlbuild
fi

call_setup_with_timeout()
{
    local SETUP_REPO=$1
    local TIMEOUT=$2
    if [ -z "$TIMEOUT" ]; then
        TIMEOUT=20m
    fi
    # give setup $TIMEOUT minutes to complete and set TERM signal. If that doesn't work,
    # send KILL 60s later
    timeout --kill-after=60s "$TIMEOUT" \
            "./${SETUP_REPO}/setup.sh" --all-layers --dl-layers --mirror --repo-verbose --accept-eula=yes
    local RET=$?
    if [ $RET != 0 ]; then
        echo "fatal: Setup command exited with $RET or timed out"
    fi
}

check_mirror_index_size()
{
    if [ -d mirror-index ]; then
        local MIRROR_INDEX_SIZE=
        MIRROR_INDEX_SIZE=$(du -sm mirror-index | cut -f1)
        if [ "$MIRROR_INDEX_SIZE" -gt 50 ]; then
            echo "Mirror index cache at $PWD has grown to over 50MB and will be deleted"
            rm -rf mirror-index
        fi
    fi
}

wrl_clone_or_update()
{
    local BRANCH=$1

    local REMOTE=
    local SETUP_REPO=
    local WRLINUX_BRANCH=
    WRLINUX_BRANCH=$(echo "${BRANCH^^}" | tr '-' '_' )
    REMOTE="https://github.com/WindRiver-Labs/wrlinux-9"
    SETUP_REPO=wrlinux-9

    cd ${BASE}
    if [ ! -f "${BASE}/wrlinux-$BRANCH/wrlinux-9/setup.sh" ]; then
        (
            mkdir -p "${BASE}/wrlinux-$BRANCH"
            cd "${BASE}/wrlinux-$BRANCH"
            rm -rf wrlinux-9
            echo "Cloning wrlinux-9 with setup program on branch $WRLINUX_BRANCH from $REMOTE"
            git clone --branch "$WRLINUX_BRANCH" --single-branch "${REMOTE}"
            echo "Mirroring wrlinux source tree with setup program on branch $BRANCH"
            call_setup_with_timeout "$SETUP_REPO" 60m
        )
    else
        (
            echo "Updating wrlinux-x on branch $WRLINUX_BRANCH"
            cd "${BASE}/wrlinux-${BRANCH}/${SETUP_REPO}"
            git fetch --quiet
            git reset --hard "origin/$WRLINUX_BRANCH"
        )
        (
            echo "Updating wrlinux source tree with setup program on branch $BRANCH"
            cd "${BASE}/wrlinux-$BRANCH/"
            check_mirror_index_size
            call_setup_with_timeout "$SETUP_REPO"
        )
    fi
}

main()
{
    echo "*************"
    echo "Starting wrlinux mirror updates"

    cd $BASE || exit 1

    local BRANCHES=$*

    local BRANCH=
    for BRANCH in $BRANCHES; do
        echo "Starting update for $BRANCH by trying to take lock"
        local LOCKFILE="${BASE}/.update-${BRANCH}.lck"
        exec 8>"$LOCKFILE"
        flock --exclusive 8
        echo "Lock for $BRANCH aquired"
        wrl_clone_or_update "$BRANCH"
        flock --unlock 8
        echo "Completed update of $BRANCH and releasing lock"
    done

    echo "Finished update"
}

main "$@"
