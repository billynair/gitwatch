#!/usr/bin/env bash
#
# gitwatch - watch file or directory and git commit all changes as they happen
#
# Copyright (C) 2013-2018  Patrick Lehner
#   with modifications and contributions by:
#   - Matthew McGowan
#   - Dominik D. Geyer
#   - Phil Thompson
#   - Dave Musicant
#
#############################################################################
#    This program is free software: you can redistribute it and/or modify
#    it under the terms of the GNU General Public License as published by
#    the Free Software Foundation, either version 3 of the License, or
#    (at your option) any later version.
#
#    This program is distributed in the hope that it will be useful,
#    but WITHOUT ANY WARRANTY; without even the implied warranty of
#    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#    GNU General Public License for more details.
#
#    You should have received a copy of the GNU General Public License
#    along with this program.  If not, see <http://www.gnu.org/licenses/>.
#############################################################################
#
#   Idea and original code taken from http://stackoverflow.com/a/965274 
#       (but heavily modified by now)
#
#   Requires the command 'inotifywait' to be available, which is part of
#   the inotify-tools (See https://github.com/rvoicilas/inotify-tools ),
#   and (obviously) git.
#   Will check the availability of both commands using the `which` command
#   and will abort if either command (or `which`) is not found.
#

REMOTE=""
BRANCH=""
SLEEP_TIME=2
DATE_FMT="+%Y-%m-%d %H:%M:%S"
COMMITMSG="Scripted auto-commit on change (%d) by gitwatch.sh"
LISTCHANGES=-1
LISTCHANGES_COLOR="--color=always"
EVENTS="close_write,move,delete,create"

# Print a message about how to use this script
shelp () {
    echo "gitwatch - watch file or directory and git commit all changes as they happen"
    echo ""
    echo "Usage:"
    echo "${0##*/} [-s <secs>] [-d <fmt>] [-r <remote> [-b <branch>]]"
    echo "          [-m <msg>] [-l|-L <lines>] <target>"
    echo ""
    echo "Where <target> is the file or folder which should be watched. The target needs"
    echo "to be in a Git repository, or in the case of a folder, it may also be the top"
    echo "folder of the repo."
    echo ""
    echo " -s <secs>        after detecting a change to the watched file or directory,"
    echo "                  wait <secs> seconds until committing, to allow for more"
    echo "                  write actions of the same batch to finish; default is 2sec"
    echo " -d <fmt>         the format string used for the timestamp in the commit"
    echo "                  message; see 'man date' for details; default is "
    echo "                  \"+%Y-%m-%d %H:%M:%S\""
    echo " -r <remote>      if given and non-empty, a 'git push' to the given <remote>"
    echo "                  is done after every commit; default is empty, i.e. no push"
    echo " -b <branch>      the branch which should be pushed automatically;"
    echo "                - if not given, the push command used is  'git push <remote>',"
    echo "                    thus doing a default push (see git man pages for details)"
    echo "                - if given and"
    echo "                  + repo is in a detached HEAD state (at launch)"
    echo "                    then the command used is  'git push <remote> <branch>'"
    echo "                  + repo is NOT in a detached HEAD state (at launch)"
    echo "                    then the command used is"
    echo "                    'git push <remote> <current branch>:<branch>'  where"
    echo "                    <current branch> is the target of HEAD (at launch)"
    echo "                  if no remote was defined with -r, this option has no effect"
    echo " -l <lines>       log the actual changes made in this commit, upto a given"
    echo "                  number of lines, or all lines if 0 is given"
    echo " -L <lines>       same as -l but without colored formatting"
    echo " -m <msg>         the commit message used for each commit; all occurences of"
    echo "                  %d in the string will be replaced by the formatted date/time"
    echo "                  (unless the <fmt> specified by -d is empty, in which case %d"
    echo "                  is replaced by an empty string); the default message is:"
    echo "                  \"Scripted auto-commit on change (%d) by gitwatch.sh\""
    echo " -e <events>      events passed to inotifywait to watch (defaults to "   
    echo "                  '$EVENTS')"
    echo "                  (useful when using inotify-win, e.g. -e modify,delete,move)"
    echo ""
    echo "As indicated, several conditions are only checked once at launch of the"
    echo "script. You can make changes to the repo state and configurations even while"
    echo "the script is running, but that may lead to undefined and unpredictable (even"
    echo "destructive) behavior!"
    echo "It is therefore recommended to terminate the script before changin the repo's"
    echo "config and restarting it afterwards."
    echo ""
    echo "By default, gitwatch tries to use the binaries \"git\" and \"inotifywait\","
    echo "expecting to find them in the PATH (it uses 'which' to check this and  will"
    echo "abort with an error if they cannot be found). If you want to use binaries"
    echo "that are named differently and/or located outside of your PATH, you can define"
    echo "replacements in the environment variables GW_GIT_BIN and GW_INW_BIN for git"
    echo "and inotifywait, respectively."
}

# print all arguments to stderr
stderr () {
    echo $@ >&2
}

# clean up at end of program, killing the remaining sleep process if it still exists
cleanup () {
    if [[ -n "$SLEEP_PID" ]] && kill -0 $SLEEP_PID &>/dev/null; then
        kill $SLEEP_PID &>/dev/null
    fi
    exit 0
}

# Tests for the availability of a command
is_command () {
	which "$1" &>/dev/null
}

###############################################################################

while getopts b:d:h:L:l:m:p:r:s:e: option # Process command line options 
do 
    case "${option}" in 
        b) BRANCH=${OPTARG};;
        d) DATE_FMT=${OPTARG};;
        h) shelp; exit;;
        l) LISTCHANGES=${OPTARG};;
        L) LISTCHANGES=${OPTARG}; LISTCHANGES_COLOR="";;
        m) COMMITMSG=${OPTARG};;
        p|r) REMOTE=${OPTARG};;
        s) SLEEP_TIME=${OPTARG};;
        e) EVENTS=${OPTARG};;
    esac
done

shift $((OPTIND-1)) # Shift the input arguments, so that the input file (last arg) is $1 in the code below

if [ $# -ne 1 ]; then # If no command line arguments are left (that's bad: no target was passed)
    shelp # print usage help
    exit # and exit
fi

# if custom bin names are given for git or inotifywait, use those; otherwise fall back to "git" and "inotifywait"
if [ -z "$GW_GIT_BIN" ]; then GIT="git"; else GIT="$GW_GIT_BIN"; fi
if [ -z "$GW_INW_BIN" ]; then INW="inotifywait"; else INW="$GW_INW_BIN"; fi

# Check availability of selected binaries and die if not met
for cmd in "$GIT" "$INW"; do
	is_command "$cmd" || { stderr "Error: Required command '$cmd' not found." ; exit 1; }
done
unset cmd

###############################################################################

SLEEP_PID="" # pid of timeout subprocess

trap "cleanup" EXIT # make sure the timeout is killed when exiting script


# Expand the path to the target to absolute path
IN=$(readlink -f "$1")

if [ -d "$1" ]; then # if the target is a directory
    TARGETDIR=$(sed -e "s/\/*$//" <<<"$IN") # dir to CD into before using git commands: trim trailing slash, if any
    INCOMMAND="\"$INW\" -qmr -e \"$EVENTS\" --exclude \"\.git\" \"$TARGETDIR\"" # construct inotifywait-commandline
    GIT_ADD_ARGS="--all ." # add "." (CWD) recursively to index
    GIT_COMMIT_ARGS="" # add -a switch to "commit" call just to be sure
elif [ -f "$1" ]; then # if the target is a single file
    TARGETDIR=$(dirname "$IN") # dir to CD into before using git commands: extract from file name
    INCOMMAND="\"$INW\" -qm -e \"$EVENTS\" \"$IN\"" # construct inotifywait-commandline
    GIT_ADD_ARGS="$IN" # add only the selected file to index
    GIT_COMMIT_ARGS="" # no need to add anything more to "commit" call
else
    stderr "Error: The target is neither a regular file nor a directory."
    exit 1
fi

# Check if commit message needs any formatting (date splicing)
if ! grep "%d" > /dev/null <<< "$COMMITMSG"; then # if commitmsg didnt contain %d, grep returns non-zero
    DATE_FMT="" # empty date format (will disable splicing in the main loop)
    FORMATTED_COMMITMSG="$COMMITMSG" # save (unchanging) commit message
fi

cd "$TARGETDIR" # CD into right dir

if [ -n "$REMOTE" ]; then # are we pushing to a remote?
    if [ -z "$BRANCH" ]; then # Do we have a branch set to push to ?
        PUSH_CMD="'$GIT' push $REMOTE" # Branch not set, push to remote without a branch
    else
        # check if we are on a detached HEAD
        HEADREF=$(git symbolic-ref HEAD 2> /dev/null)
        if [ $? -eq 0 ]; then # HEAD is not detached
            PUSH_CMD="'$GIT' push $REMOTE $(sed "s_^refs/heads/__" <<< "$HEADREF"):$BRANCH"
        else # HEAD is detached
            PUSH_CMD="'$GIT' push $REMOTE $BRANCH"
        fi
    fi
else
    PUSH_CMD="" # if not remote is selected, make sure push command is empty
fi

# A function to reduce git diff output to the actual changed content, and insert file line numbers.
# Based on "https://stackoverflow.com/a/12179492/199142"
diff-lines() {
    local path=
    local line=
    while read; do
        esc=$'\033'
        if [[ $REPLY =~ ---\ (a/)?.* ]]; then
            continue
        elif [[ $REPLY =~ \+\+\+\ (b/)?([^[:blank:]$esc]+).* ]]; then
            path=${BASH_REMATCH[2]}
        elif [[ $REPLY =~ @@\ -[0-9]+(,[0-9]+)?\ \+([0-9]+)(,[0-9]+)?\ @@.* ]]; then
            line=${BASH_REMATCH[2]}
        elif [[ $REPLY =~ ^($esc\[[0-9;]+m)*([\ +-]) ]]; then
            echo "$path:$line: $REPLY"
            if [[ ${BASH_REMATCH[2]} != - ]]; then
                ((line++))
            fi
        fi
    done
}

###############################################################################

# main program loop: wait for changes and commit them
#   whenever inotifywait reports a change, we spawn a timer (sleep process) that gives the writing
#   process some time (in case there are a lot of changes or w/e); if there is already a timer
#   running when we receive an event, we kill it and start a new one; thus we only commit if there
#   have been no changes reported during a whole timeout period
eval $INCOMMAND | while read -r line; do 
    # is there already a timeout process running?
    if [[ -n "$SLEEP_PID" ]] && kill -0 $SLEEP_PID &>/dev/null; then
        # kill it and wait for completion
        kill $SLEEP_PID &>/dev/null || true
        wait $SLEEP_PID &>/dev/null || true
    fi

    # start timeout process
    (
        sleep $SLEEP_TIME # wait some more seconds to give apps time to write out all changes

        if [ -n "$DATE_FMT" ]; then
            FORMATTED_COMMITMSG="$(sed "s/%d/$(date "$DATE_FMT")/" <<< "$COMMITMSG")" # splice the formatted date-time into the commit message
        fi

        if [[ "$LISTCHANGES" -ge 0 ]]; then    # allow listing diffs in the commit log message, unless if there are too many lines changed
            DIFF_COMMITMSG="$(git diff -U0 $LISTCHANGES_COLOR | diff-lines)"
            LENGTH_DIFF_COMMITMSG=0
            if [[ "$LISTCHANGES" -ge 1 ]]; then
                LENGTH_DIFF_COMMITMSG=$(echo -n "$DIFF_COMMITMSG" | grep -c '^')
            fi
            if [[ "$LENGTH_DIFF_COMMITMSG" -le $LISTCHANGES ]]; then
                FORMATTED_COMMITMSG="$DIFF_COMMITMSG"
            else
                #FORMATTED_COMMITMSG="Many lines were modified. $FORMATTED_COMMITMSG"
                FORMATTED_COMMITMSG=$(git diff --stat | grep '|')
            fi
        fi

        cd "$TARGETDIR" # CD into right dir
        "$GIT" add $GIT_ADD_ARGS # add file(s) to index
        "$GIT" commit $GIT_COMMIT_ARGS -m"$FORMATTED_COMMITMSG" # construct commit message and commit

        if [ -n "$PUSH_CMD" ]; then eval $PUSH_CMD; fi
    ) & # and send into background

    SLEEP_PID=$! # and remember its PID
done
