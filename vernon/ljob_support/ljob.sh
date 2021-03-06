#! /bin/bash
#
# Launch multiple SLURM jobs to process tasks. We set up a work directory,
# and submit the jobs.

if [ -z "$VERNON_DEBUG_LJOB" ] ; then
    debug=false
else
    debug=true
    echo "NOTE: operating in local-debug mode"
fi

function die () {
    echo >&2 ljob: "$@"
    exit 1
}


# "process" - launch jobs to process tasks in the current directory

function process() {
    work="$1"
    shift

    if [ -z "$work" ] ; then
        echo >&2 "usage: ljob process <workdir> [-N maxattempts] [-t maxtime] [-n nworkers]"
        echo >&2 "  [-m mem] [-p partition] [-i identifier] [-r taskidregex] [--machine-output]"
        exit 1
    fi

    [ -f "$work"/tasks ] || die "work directory $work not yet seeded"

    # Default settings.

    workerpartition=serial_requeue
    maxtime=360
    nworkers=4
    mem=2048
    ident=process
    machine_output=false

    # Overrides?

    while [ $# -gt 0 ] ; do
        case $1 in
            --machine-output) shift; machine_output=true ;;
	    -N) shift; maxattempts="$1"; shift ;;
	    -t) shift; maxtime="$1"; shift ;;
	    -n) shift; nworkers="$1"; shift ;;
	    -m) shift; mem="$1"; shift ;;
	    -p) shift; workerpartition="$1"; shift ;;
	    -i) shift; ident="$1"; shift ;;
	    -r) shift; taskidregex="$1"; shift ;;
	    *) die "unexpected argument \"$1\"" ;;
        esac
    done

    if ! $machine_output ; then
        echo "Request: $nworkers workers, maxtime $maxtime, mem $mem, $workerpartition partition"
    fi

    # Go.

    set -e

    work=$(cd "$work" && pwd -P) # $work is assumed to be absolute in a few places

    set -o noclobber
    echo launch >"$work"/lock
    set +o noclobber

    shopt -s nullglob
    last=$((cd "$work" && for x in [0-9][0-9].* ; do echo $x ; done) |sort -n |tail -n1)
    if [ -z "$last" ] ; then
        seq=00
    else
        # bash's $(()) thinks 09 is an invalid number because it interprets it as
        # octal due to the leading zero.
        seq=$(printf "%02d" $((1 + $(echo $last |cut -d. -f1 |sed -e 's/^0//'))))
    fi

    datecode=$(date +%m%d_%H%M)
    jobname=$(basename "$work")."$seq"
    passid="${seq}.${ident}.${datecode}"
    inner="$work/$passid"
    mkdir "$inner"
    rm -f "$work"/lock

    # Prep work directory.

    if $machine_output ; then
        echo "work=$inner"
    else
        echo "Setting up work directory $inner ..."
    fi

    cp $LJOB_SUPPORT/wrapper.sh $inner/wrapper.sh
    mkdir $inner/worker-outerlogs
    cp -p $LJOB_SUPPORT/postprocess.py $inner/
    cp $LJOB_SUPPORT/ljob-postprocessor-launcher.sh $inner/postprocess.sh
    [ -z "$maxattempts" ] || echo "$maxattempts" >"$inner"/maxattempts.txt
    [ -z "$taskidregex" ] || echo "$taskidregex" >"$inner"/taskidregex.txt
    echo "$passid" >"$inner"/passid.txt
    echo "$jobname" >"$inner"/jobname.txt

    bulkgroup=$TOP/.bulkjobdata/$(date +%y%m)
    mkdir -p "$bulkgroup"
    bulk=$(mktemp -d --tmpdir="$bulkgroup" $(date +%d).$jobname.XXX)
    chmod 770 $bulk # accessible by whole panstarrs group
    ln -s $bulk $inner/bulkdata

    # Launch the master
    #
    # It turns out that the only way to get a truly pristine environment for your
    # batch process is to use the --export-file option, since --export triggers
    # --get-user-env. So that's what we do.
    #
    # We're screwed if the master job gets cancelled, so we can't run it on the
    # serial_requeue queue. It must always be run on general.

    sbargs="-D $inner --mem $mem -t $maxtime --parsable"
    sbargs="$sbargs --open-mode=append"
    printf "PATH=/usr/bin:/bin\0HOME=$HOME\0USER=$USER\0TOP=$TOP\0LJOB_IS_MASTER=y" >$inner/master.sbenv
    printf "PATH=/usr/bin:/bin\0HOME=$HOME\0USER=$USER\0TOP=$TOP\0LJOB_IS_MASTER=n" >$inner/worker.sbenv

    (date +%s ; date) >$inner/submit.wallclock
    if $debug ; then
        LJOB_IS_MASTER=y SLURM_JOB_ID=master bash $inner/wrapper.sh |& tee $inner/ljob.log &
    else
        sbatch $sbargs --export-file=$inner/master.sbenv -J $jobname.master \
            -o $inner/outer.log --no-requeue -p general,shared,unrestricted \
	    $inner/wrapper.sh >$inner/launchjobid
        mjobid=$(cat $inner/launchjobid)
    fi

    if $machine_output ; then
        echo "masterjobid=$mjobid"
    else
        echo "Submitted processing job $jobname, master ID $mjobid."
    fi

    # Launch workers

    if $debug ; then
        for i in $(seq 1 $nworkers) ; do
	    LJOB_IS_MASTER=n SLURM_JOB_ID=w$i bash $inner/wrapper.sh >& $inner/worker-outerlogs/w$i &
        done
    else
        sbatch $sbargs --export-file=$inner/worker.sbenv -J $jobname.worker \
	    -o $inner/worker-outerlogs/%j -d "after:$mjobid" -p $workerpartition \
	    --array=1-$nworkers $inner/wrapper.sh >$inner/worker-arraymasterids
    fi

    if $machine_output ; then
        echo "arrayjobid=$(cat $inner/worker-arraymasterids)"
    else
        echo "Submitted array of $nworkers workers, array ID $(cat $inner/worker-arraymasterids)"
    fi

    ###if ! $debug ; then
    ###    sbatch -D $inner --mem 64 -t 10 --parsable --open-mode=append -J $jobname.postprocess \
    ###        --export-file=$inner/master.sbenv -o $inner/ppouter.log -p $workerpartition \
    ###        -d "afterany:$mjobid" \
    ###        $inner/postprocess.sh >$inner/ppjobid
    ###    echo "Submitted postmortem processing/notification job."
    ###fi

    if $debug ; then
        trap "kill $(jobs -p |tr '\n' ' ')" SIGINT # kill all workers on exit
        wait
    fi
}


# Dispatcher

subcommand="$1"
shift

if [ -z "$subcommand" ] ; then
    echo "usage: ljob process ..."
    exit 1
fi

case "$subcommand" in
    process) process "$@" ;;
    *) die "unrecognized subcommand \"$subcommand\"" ;;
esac
