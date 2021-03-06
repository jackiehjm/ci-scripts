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

#this function takes a log message and prefixes a timestamp
function log
{
    #This timestamp is sortable, has milliseconds and timezone
    #This allows log files to be merged consistently
    timestamp=$(date --rfc-3339=ns)
    echo "[${timestamp}] $1"
}

#This will pass the output of scripts like fix-config through log to add timestamps
#Stolen from here: http://serverfault.com/questions/310098/adding-a-timestamp-to-bash-script-log
#IFS= tells read to not strip whitespace
#read -r ignores the escape character
function log_stdout
{
    while IFS= read -r line; do
        #need quotes to pass text as single argument
        log "$line"
    done
}

function random_char
{
    local VALID_CHARS=abcdefghijklmnopqrstuvwxyz0123456789
    local RANDOM_INDEX=$(( $RANDOM % ${#VALID_CHARS} ))
    echo -n ${VALID_CHARS:$RANDOM_INDEX:1}
}

function random_char_seq
{
    local char_seq=
    for arg in $(seq 1 $1); do
        char_seq="$char_seq$(random_char)"
    done
    echo -n $char_seq
}

function create_build_dir
{
    if [ -n "$MESOS_TASK_ID" ]; then
        BUILD="$TOP/builds/builds-$MESOS_TASK_ID"
    else
        while :
        do
            local DATE=$(date --iso-8601=date)
            local NEW_TIME=$(date +'%H%M%S')
            local RAND_STR="$DATE-$NEW_TIME-$(random_char_seq 4)"
            BUILD="$TOP/builds/builds-$RAND_STR"
            if [ ! -d "$BUILD" ]; then
                break
            fi
            sleep 1
        done
    fi
    mkdir -p "$BUILD"

    if [ $? != 0 ]; then
        log "something evil happened, mkdir $BUILD failed"
        exit 1
    fi
    # Make sure build dir is writable by uid 1000
    # In docker containers, wrlbuild has passwordless sudo access
    local BUILDDIR_UID=$(stat -c '%u' "$BUILD")
    if [ "$BUILDDIR_UID" -ne "1000" ] && [ "$USER" == "wrlbuild" ]; then
        sudo chown -R 1000:100 "$BUILD"
    fi
    log "Creating build directory \"${BUILD##*/}\""
}

#write stats to stats file
function log_stats
{
    local STAGE=$1
    local BUILD=$2
    local STATFILE=$BUILD/buildstats.log
    echo "$STAGE End: $(date +%s)" >> "$STATFILE"
    local seconds=$(tail -n 1 "$BUILD/time.log" | cut -d. -f1)
    echo "$STAGE Elapsed Seconds: $seconds" >> "$STATFILE"
    local hours=$((seconds / 3600))
    seconds=$((seconds % 3600))
    local minutes=$((seconds / 60))
    seconds=$((seconds % 60))
    echo "$STAGE Elapsed Hours: $hours:$minutes:$seconds" >> "$STATFILE"
}

# check the "something failed (?)" failures
function check_error
{
    local WRBUILDLOG=$(dirname "$1")/00-wrbuild.log
    local MSG=

    if [ -f "$WRBUILDLOG" ]; then
        if grep 'ERROR: Nothing [RPROVIDES|PROVIDES]' "$WRBUILDLOG" >/dev/null; then
            MSG=$(grep 'ERROR: Nothing [RPROVIDES|PROVIDES]' "$WRBUILDLOG" | tail -n1 | sed -e 's=.*ERROR: \(.*\) (.*=\1=')
        elif grep 'ERROR: .*timeout while attempting to communicate with bitbake server' "$WRBUILDLOG" >/dev/null; then
            MSG="Communicate with bitbake server Timeout"
        elif grep 'ERROR: QA Issue:' "$WRBUILDLOG" >/dev/null; then
            MSG=$(grep 'ERROR: QA Issue:' "$WRBUILDLOG" | tail -n1 | sed -e 's=.*\[\(.*\)\]=\1=')
            case $MSG in
            already-stripped)
                MSG="QA Error (file already-stripped)"
                ;;
            '')
                ;;
            *)
                MSG="QA Error (?)"
                ;;
            esac
        fi
    fi

    echo $MSG
}

####### fail_pkg
fail_pkg()
{
    local WRBUILDLOG=$(dirname "$1")/00-wrbuild.log
    local PKG=
    # take a stab at guessing the pkg failure
    if [ -f "$WRBUILDLOG" ]; then
        PKG=$(grep '^\[.*\] ERROR: Task [0-9]' "$WRBUILDLOG" | tail -n1 | sed 's=.*/\([-a-zA-Z0-9_%\.\+]*\)\.bb,.*=\1=')
        if [ -z "$PKG" ]; then
            PKG=$(grep '^\[.*\] ERROR: Task ' "$WRBUILDLOG" | tail -n1 | sed 's=.*/\([-a-zA-Z0-9_%\.\+]*\)\.bb:.*=\1=')
        fi
    else
        PKG="configure"
    fi
    if [ -z "$PKG" ]; then
        PKG="something"
    fi
    echo $PKG
}

####### fail_step
fail_step()
{
    local WRBUILDLOG=$(dirname "$1")/00-wrbuild.log
    local STEP=""
    # take a stab at guessing the step within the pkg failure
    if [ -f "$WRBUILDLOG" ]; then
        STEP=$(grep '^\[.*\] ERROR: Task [0-9]' "$WRBUILDLOG" | tail -n1 | sed 's=.*\.bb, \(do_[a-zA-Z0-9_-]*\).*=\1=')
        if [ -z "$STEP" ]; then
            STEP=$(grep '^\[.*\] ERROR: Task ' "$WRBUILDLOG" | tail -n1 | sed 's=.*\.bb:\(do_[a-zA-Z0-9_-]*\).*=\1=')
        fi
    fi
    if [ -z "$STEP" ]; then
        STEP="?"
    fi
    echo $STEP
}


####### fail_log
fail_log()
{
    local WRBUILDLOG=$(dirname "$1")/00-wrbuild.log
    local LOG=""
    if [ -f "$WRBUILDLOG" ]; then
        LOG=$(grep '^\[.*\] ERROR: Logfile of failure stored in:' "$WRBUILDLOG" |head -n1 |sed 's/^\[.*\] ERROR:.* in: //')
    fi
    echo $LOG
}

######### store logs on a server
store_logs()
{
    # git dir, which will be the failed build dir.
    local GDIR=$1
    local MFILE=$2
    local BUILD_NAME=$(basename $GDIR)
    local PKG=$(fail_pkg $GDIR)
    local PKG_LOG=$(fail_log $GDIR)

    cd $GDIR || return 1

    git init > /dev/null 2>&1

    if [ $? != 0 ]; then
        log "git init in $GDIR failed"
        return 1
    fi

    #cooker logs have moved with oe-core 1.5
    local COOKER=
    if [ -d "bitbake_build/tmp/log" ]; then
        COOKER=$(ls -tr bitbake_build/tmp/log/cooker/*/*.log 2> /dev/null | tail -1)
    else
        COOKER=$(ls -tr bitbake_build/tmp/cooker* 2> /dev/null | tail -1)
    fi

    if [ -f "$BUILD/00-wrbuild.log" ]; then
        cp $BUILD/00-wrbuild.log $GDIR
    fi
    if [ -f "$BUILD/buildstats.log" ]; then
        cp $BUILD/buildstats.log $GDIR
    fi
    cp $BUILD/00-wrconfig.log $GDIR
    cp $MFILE $GDIR

    for i in  \
        00-wrbuild.log 00-wrconfig.log config.log buildstats.log \
        $(basename $MFILE) $PKG_LOG $COOKER bitbake_build/tmp/qa.log ; do
        if [ -f $i ]; then
            git add -f $i > /dev/null 2>&1
            if [ $? != 0 ]; then
                log "git add of $i in $GDIR failed"
                return 1
            fi
        fi
    done

    if [ -n "$PKG" ]; then
        # See if we can find any additional pkg logs too.
        local PKG_DIR=$(echo build/$PKG-*|awk '{print $1}')
        if [ -d "$PKG_DIR" ]; then
            for i in $(find $PKG_DIR/temp -name 'run\.*[0-9]') ; do
                git add $i > /dev/null 2>&1
                if [ $? != 0 ]; then
                    log "git add of $i in $GDIR failed"
                    return 1
                fi
            done
        fi
    fi

    git commit -m "build logs for $PKG $BUILD_NAME" > /dev/null 2>&1
    if [ $? != 0 ]; then
        log "git commit in $GDIR failed"
        return 1
    fi

    #Make a bare clone with logs to be handled by post process script
    cd $BUILD
    git clone --bare $BUILD_NAME faillogs.git

    return 0;
}


function generate_failmail
{
    local BUILD=$1
    local BUILD_NAME=$2
    local FAIL="$1/$2"
    local MFILE=$BUILD/mail.txt
    local LOGLINES=150

    local PKG=$(fail_pkg "$FAIL")
    local PKG_LOG=$(fail_log "$FAIL")
    local STEP=$(fail_step "$FAIL")
    local MSG=
    if [ $PKG = something ]; then
        MSG=$(check_error "$FAIL")
    fi

    local STATFILE=$BUILD/buildstats.log
    sed -i '/PackageFailed:/d' "$STATFILE"
    echo "PackageFailed: $PKG\($STEP\)" >> "$STATFILE"

    local MACHINE=$(get_stat 'Machine')
    local ARCH=$(get_stat 'Arch')
    local BRANCH=$(get_stat 'Branch')
    local CONFIGARGS=($(get_stat 'Config'))
    local PREBUILD=
    local SETUPARGS=
    if [ -z "${CONFIGARGS[*]}" ]; then
        PREBUILD=($(get_stat 'Prebuild'))
        SETUPARGS=($(get_stat 'Setup'))
    fi

    local REASON=$(get_stat 'Reason')

    local SUBJECT=
    if [ -n "$MSG" ]; then
        SUBJECT="$MSG of $BUILD_NAME."
    elif [ "$REASON" == "KILLED" ]; then
        SUBJECT="$BUILD_NAME detected as hung and killed."
    elif [ "$REASON" == "TIMEOUT" ]; then
        SUBJECT="Docker container for $BUILD_NAME was stopped by Mesos Agent."
    else
        SUBJECT="$PKG failed ($STEP) of $BUILD_NAME."
    fi

    {
        echo "Subject: [ci-scripts] $SUBJECT"
        echo ""
        echo "Build in $MACHINE $ARCH"
        echo "Branch being built is $BRANCH"
        echo Logfiles are 00-wrconfig.log and 00-wrbuild.log
        echo Relevant bits of the config were:
        if [ -n "${CONFIGARGS[*]}" ]; then
            echo "    ${CONFIGARGS[*]}"
        else
            echo "    setup.sh ${SETUPARGS[*]}"
            echo "    ${PREBUILD[*]}"
            echo "    ${BUILD_CMD[*]}"
        fi
        echo ""

        local BUILDLOG=$BUILD/00-wrbuild.log
        if [ -f "$BUILDLOG" ]; then
            #build config can occur multiple times in file. Only extract first one
            head -n 60 "$BUILDLOG" | sed -n '/Build Configuration:/,/^$/p'
        fi
        echo "Failed step: $STEP in file: $PKG_LOG"
        echo ""
        if [ "$REASON" == "KILLED" ]; then
            local SETUPLOG=$BUILD/00-wrsetup.log
            if [ -f "$SETUPLOG" ]; then
                echo Here is some context from 00-wrsetup.log
                echo " --------------------------------------------------"
                if [ `cat $SETUPLOG | wc -m` -lt 4000 ]; then
                    cat $SETUPLOG | fold -b -w 500
                else
                    tail -n "$LOGLINES" | fold -b -w 500
                fi
                cat "$SETUPLOG"
                echo ""
            fi
            local DOCKERLOG=$BUILD/00-DOCKER.log
            if [ -f "$DOCKERLOG" ]; then
                echo Here is some context from 00-DOCKER.log
                echo " --------------------------------------------------"
                echo "docker log:"
                cat "$DOCKERLOG" | fold -b -w 500
                echo ""
            fi
        fi
        echo Here is some context from around the error:
        echo " --------------------------------------------------"

        # Send email has a 998 char line length limit.
        if [ -f "$BUILDLOG" ]; then
            # cat all the buildlogs if the log file < 4k
            if [ `cat $BUILDLOG | wc -m` -lt 4000 ]; then
                cat $BUILDLOG | fold -b -w 500
            else
                grep -C3 '^\[.*\] ERROR:' "$BUILDLOG" | tail -n "$LOGLINES" | fold -b -w 500
            fi
        else
            tail -n "$LOGLINES" "$BUILD/00-wrconfig.log" | fold -b -w 500
        fi
        echo " --------------------------------------------------"

        if [ -f "$PKG_LOG" ]; then
            echo ""
            echo "Here is the tail of $(basename "$PKG_LOG"):"
            echo " --------------------------------------------------"
            local PKG_LOG_SIZE=`tail -n "$LOGLINES" "$PKG_LOG" | wc -m`
            if [ $PKG_LOG_SIZE -lt $MAX_LOGDATA_SIZE ]; then
                tail -n "$LOGLINES" "$PKG_LOG" | fold -b -w 500
            else
                echo -n "..."
                tail -c "$MAX_LOGDATA_SIZE" "$PKG_LOG" | fold -b -w 500
            fi
            echo " --------------------------------------------------"
        fi

        local QA_LOG="${BUILD}/${BUILD_NAME}/bitbake_build/tmp/qa.log"
        if [ -f "$QA_LOG" ]; then
            echo ""
            echo "Here is the tail of qa.log"
            echo " --------------------------------------------------"
            tail -n "$LOGLINES" "$QA_LOG" | fold -b -w 500
            echo " --------------------------------------------------"
        fi

        if [ -n "$PUSH_HOST" ]; then
            local FAIL_BRANCH=$BUILD_NAME-$PKG-$(date +'%F-%H%M%S')
            local LOGLINK="http://$PUSH_HOST/cgit/$FAIL_REPO/.git/log/?h=${FAIL_BRANCH//%/%25}"
            echo " --------------------------------------"
            echo " "
            echo This file, and more detailed log info can be found at:
            echo "$LOGLINK"
            echo "To reproduce this failure with a local docker instance, see wraxl docs:"
            echo "  http://ala-git.wrs.com/cgi-bin/cgit.cgi/lpd-ops/wr-buildscripts.git/tree/README.md"
            sed -i '/FailBranch:/d' "$STATFILE"
            echo "FailBranch: $FAIL_BRANCH" >> "$STATFILE"
            sed -i '/LogLink:/d' "$STATFILE"
            echo "LogLink: $LOGLINK" >> "$STATFILE"
        fi
    } > "$MFILE"

}

function generate_successmail() {
    local BUILD=$1
    local BUILD_NAME=$2
    local MFILE=$BUILD/mail.txt
    local BUILDLOG=$BUILD/00-wrbuild.log
    local MACHINE=$(get_stat 'Machine')
    local ARCH=$(get_stat 'Arch')
    local BRANCH=$(get_stat 'Branch')
    local CONFIGARGS=($(get_stat 'Config'))
    {
        echo "Subject: [ci-scripts] Build $BUILD_NAME Succeeded."
        echo ""
        echo "Build in $MACHINE $ARCH"
        echo "Branch being built is $BRANCH"
        echo Relevant bits of the config were:
        echo "     ${CONFIGARGS[*]}"
        echo ""

        if [ -f "$BUILDLOG" ]; then
            #build config can occur multiple times in file. Only extract first one
            head -n 60 "$BUILDLOG" | sed -n '/Build Configuration:/,/^$/p'
        fi
    } > "$MFILE"
}

function generate_mail() {
    local BUILD=$1
    local BUILD_STATUS=$(get_stat 'Status')
    local BUILD_NAME=$(get_stat 'Name')
    if [ "$BUILD_STATUS" == "PASSED" ]; then
        generate_successmail "$BUILD" "$BUILD_NAME"
    elif [ "$BUILD_STATUS" == "FAILED" ]; then
        generate_failmail "$BUILD" "$BUILD_NAME"
    fi
}

function setup_use_native_sstate() {
    local ARCH=$1
    local BRANCH=$2
    local BUILD=$3
    local BUILD_NAME=$4
    local TOP=$5
    local NATIVE_SSTATE="$TOP/host-tools-$ARCH-$BRANCH.tar.gz"
    if [ -f "$NATIVE_SSTATE" ]; then
        log "Extracting host-tools for $BRANCH on $ARCH to $BUILD_NAME/sstate-cache/"
        tar xzf "$NATIVE_SSTATE" --directory "$BUILD/$BUILD_NAME"
        mv "$BUILD/$BUILD_NAME/host-tools-x86_64" "$BUILD/$BUILD_NAME/sstate-cache"
    fi
}

function wrlinux_setup_clone() {
    local WRLINUX=$1
    local BUILD=$2
    local BRANCH=$3
    local TOP=$4
    # clone the setup program from the local mirror
    git clone --single-branch --branch "$BRANCH" "$WRLINUX" 2>&1
    log "Finished clone of wrlinux setup repository"
}

function trigger_postprocess {
    local STATFILE=$1
    rm -f "$BUILD/00-INPROGRESS"
    #Creating these files will trigger post processing
    local BUILD_STATUS=$(get_stat 'Status')
    if [ "$BUILD_STATUS" == "PASSED" ]; then
        touch "$BUILD/00-PASS"
    elif [ "$BUILD_STATUS" == "FAILED" ]; then
        touch "$BUILD/00-FAIL"
    fi
    if [ -f "${MESOS_SANDBOX}/stdout" ]; then
        cp -f "${MESOS_SANDBOX}/stdout" "$BUILD"
    fi
}

function get_container_id {
    # Retrieve the docker container id from within the container
    local CONTAINERID=$(grep 'docker' /proc/self/cgroup | sed 's/^.*\///' | tail -n1)
    echo -n "$CONTAINERID"
}

# taken from http://stackoverflow.com/questions/4023830/bash-how-compare-two-strings-in-version-format
function vercomp {
    if [[ "$1" == "$2" ]]; then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

# Build information is passed between scripts using the buildstats.log
# file. This function hides the call to awk
function get_stat() {
    # Search for line that starts with variable requested
    # awk splits on whitespace, so remove the first split and
    # print the rest. Use substr to remove the leading space
    awk '/^'$1': / {$1=""; print substr($0,2)}' "$BUILD/buildstats.log"
}

function add_cgroup_stats() {
    local STATFILE="$1"
    #retrieve cgroup stats if host cgroup dir mounted inside container
    local CGROUP='/sys/fs/cgroup'
    if [ -d "$CGROUP/cpuacct" ]; then
        local DOCKER_ID=$(grep "docker" /proc/self/cgroup | sed s/\\//\\n/g | tail -1)
        local MAXMEM=$(cat "${CGROUP}/memory/docker/${DOCKER_ID}/memory.max_usage_in_bytes")
        local CPUACCT_STATS=$(cat "${CGROUP}/cpuacct/docker/${DOCKER_ID}/cpuacct.stat")
        local CPU_USER=$(echo "$CPUACCT_STATS" | head -n 1 | cut -d' ' -f 2)
        local CPU_SYSTEM=$(echo "$CPUACCT_STATS" | tail -n 1 | cut -d' ' -f 2)
        {
            echo "Max Memory: $MAXMEM"
            echo "User CPU: $CPU_USER"
            echo "System CPU: $CPU_SYSTEM"
            echo "Total CPU: $((CPU_USER + CPU_SYSTEM))"
        } >> "$STATFILE"
    fi

}

# Emit useful error message, exit.
die() {
    echo >&2 "ERROR: $*"
    exit 1
}

create_statfile() {
    local STATFILE=$1
    {
        echo "Name: $BUILD_NAME"
        echo "Branch: $BRANCH"
        if [ -n "$TOOLCHAIN_BRANCH" ]; then
            echo "Toolchain Branch: $TOOLCHAIN_BRANCH"
        fi
        if [ -n "$EMAIL" ]; then
            echo "Email: $EMAIL"
        fi
        if [ -n "$BUILD_ID" ]; then
            echo "build_id: $BUILD_ID"
        fi
        if [ -n "$BUILD_NUM" ]; then
            echo "build_num: $BUILD_NUM"
        fi
        echo "TaskID: $MESOS_TASK_ID"
        echo "Machine: $HOST"
        echo "Arch: $(uname -m)"
        echo "Builder: $MESOS_AGENT_HOSTNAME"
        echo "ContainerID: $(get_container_id)"
        if [ -n "$REDIS_SERVER" ]; then
            echo "Redis: $REDIS_SERVER"
        fi
        echo "Start: $(date)"
        echo "StartUTC: $(date +%s)"
    } >> "$STATFILE"
}

create_test_statfile() {
    local STATFILE=$1
    {
        echo -e "\nBuild info:"
        echo "==========="
        echo "Name: $NAME"
        if [ -n "$TOOLCHAIN_BRANCH" ]; then
            echo "Toolchain Branch: $TOOLCHAIN_BRANCH"
        fi
        if [ -n "$BUILD_ID" ]; then
            echo "build_id: $BUILD_ID"
        fi
        if [ -n "$BUILD_NUM" ]; then
            echo "build_num: $BUILD_NUM"
        fi
        echo -e "\nTest info:"
        echo "=========="
        if [ -n "$EMAIL" ]; then
            echo "Email: $EMAIL"
        fi
        echo "Start: $(date) ($(date +%s))"
    } >> "$STATFILE"
}

function get_wrlinux_version() {
    local BUILD=$1
    local SETUPLOG=$BUILD/00-wrsetup.log
    local KEYWORD="Build tools installer version "

    if [ -f "$SETUPLOG" ]; then
        local INSTALLER_VER=
        INSTALLER_VER=$(cat "$SETUPLOG" | grep "$KEYWORD" | sed "s/$KEYWORD//g")
        if [ -n "$INSTALLER_VER" ]; then
            IFS='.' read -ra WRL_VER <<< "$INSTALLER_VER"
            echo "${WRL_VER[0]}"
        fi
    fi
}

function detect_built_images() {
    local BUILD=$1
    local NAME=$2

    local WRL_VER=
    WRL_VER=$(get_wrlinux_version "$BUILD")
    if [ "$WRL_VER" == "10" ]; then
        TMP_DIR=tmp-glibc
    else
        TMP_DIR=tmp
    fi

    local IMG_DIR="${BUILD}/${NAME}/${TMP_DIR}/deploy/images"

    if [ -d "$IMG_DIR" ]; then
        for image in "bzImage" "hddimg" "tar.bz2" "manifest"; do
            find "$IMG_DIR" -name "*${image}"
        done
    fi
}
