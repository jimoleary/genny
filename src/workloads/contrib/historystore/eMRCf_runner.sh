#!/bin/bash

# A lot of details are hardcoded into the script, such as the ports each node uses.  
# If this script gets used enough, these things should be parameterized.

mongo_bin=~/mdb/bin             # Where to find the MongoDB binaries
db_dir=/user_home/test          # Location where the mongod's can put their db files
db_dir=~/test          # Location where the mongod's can put their db files
genny_dir=~/src/genny           # Path to top-level directory of Genny source
metrics_dir=~/proj/metrics      # Directory where the test will store results and other output

rm -rf $metrics_dir/*

PATH=$mongo_bin:$PATH
export PATH

usage() {
    echo "usage: $0 [-fb][-g iters][-m dir]"
    echo "    -b        baseline run; don't kill secondary node in replset"
    echo "    -f        set enableMajorityReadConcern to false (default true)"
    echo "    -g iters  number of iterations to run of HS grow phase (default 10)"
    echo "    -m dir    directory to store metrics data"
    echo "    -n        no secondary restart, only primary"
    echo "    -r        reconfig secondary"
    echo "    -p        plot performance after run (requires gnuplot)"
    
    exit 1
}


start_psa() {

    hosts=(md0 md1  md2)
    # killall -9 mongos &> /dev/null
    # killall -9 mongod &> /dev/null
    for host in "${hosts[@]}"; do
        echo "$host"
        ssh $host "killall -9 mongos ; killall -9 mongod " &> /dev/null
        ssh $host << EOF
sed '/export WIREDTIGER_CONFIG=/d' -i.bak .bashrc
echo "export WIREDTIGER_CONFIG=\"${WIREDTIGER_CONFIG}\"" >> .bashrc
EOF
    done
    sleep 1
    # for host in "${hosts[@]}"; do
    #     for n in {1..3}
    #     do
    #         ssh $host "echo $(hostname); rm -rfv $db_dir/node$n/db/\*;mkdir -pv $db_dir/node$n/db"
    #     done
    # done
    for host in "${hosts[@]}"; do
        ssh $host "echo $(hostname); rm -rfv $db_dir/;mkdir -pv $db_dir/node{1..3}/db"
    done

    ssh md0 "~/bin/mongod --bind_ip_all --replSet rs --dbpath $db_dir/node1/db --logpath $db_dir/node1/db/mongod.log --port 27017 --fork $mongo_opts"
    ssh md1 "~/bin/mongod --bind_ip_all --replSet rs --dbpath $db_dir/node2/db --logpath $db_dir/node2/db/mongod.log --port 27018 --fork $mongo_opts"
    ssh md2 "~/bin/mongod --bind_ip_all --replSet rs --dbpath $db_dir/node3/db --logpath $db_dir/node3/db/mongod.log --port 27019 --fork $mongo_opts"

    # if [[ ! -z "$wiredtiger_opts" ]]; then 
    #     ssh md0 "export wiredtiger_opts=\"${wiredtiger_opts}\"; ~/bin/mongo --port 27017 admin --eval 'db.adminCommand({setParameter: 1,wiredTigerEngineRuntimeConfig: \"$wiredtiger_opts\"})'"
    #     ssh md1 "export wiredtiger_opts=\"${wiredtiger_opts}\"; ~/bin/mongo --port 27018 admin --eval 'db.adminCommand({setParameter: 1,wiredTigerEngineRuntimeConfig: \"$wiredtiger_opts\"})'"
    #     ssh md2 "export wiredtiger_opts=\"${wiredtiger_opts}\"; ~/bin/mongo --port 27019 admin --eval 'db.adminCommand({setParameter: 1,wiredTigerEngineRuntimeConfig: \"$wiredtiger_opts\"})'"
    # fi
    ssh md0 "~/bin/mongo --eval 'rs.initiate()'" &> /dev/null
    ssh md0 "~/bin/mongo --eval 'rs.add(\"md1:27018\")'" &> /dev/null
    ssh md0 "~/bin/mongo --eval 'rs.addArb(\"md2:27019\")'" &> /dev/null
    sleep 2
    ssh md0 "~/bin/mongo --eval 'rs.status()' | grep -e 'name' -e 'stateStr'"
}

restart_primary() {

    ssh md0 "~/bin/mongo --port 27017 admin --eval 'db.adminCommand({replSetStepDown:1, force: true});  db.shutdownServer()'"
    ssh md0 "pgrep -laf mongod"
    ssh md0 "ls -lah  $db_dir/node1/db/" | tee ./recovery-size.log

    sleep 2
    ssh md0 "~/bin/mongod --bind_ip_all --replSet rs --dbpath $db_dir/node1/db --logpath $db_dir/node1/db/mongod.log --port 27017 --fork $mongo_opts"

    ssh md0 "egrep 'WiredTiger opened|WT_VERB_RECOVERY' $db_dir/node1/db/mongod.*" | tee ./recovery.log
    sleep 2
    ssh md0 "~/bin/mongo --eval 'rs.status()' | grep -e 'name' -e 'stateStr'"
}

reconfig_votes() {
    local reconfig=${1:-no}
    echo "reconfig_votes: ${reconfig}"
    if [ "$reconfig" = "yes" ]; then
        echo "Reconfiguring Secodary to have no votes"
        ssh md0 "~/bin/mongo --port 27017 admin" <<EOF
let config = rs.config();
config.members[1].votes = 0;
config.version += 1;
config.members[1].priority = 0;
printjson(config);
rs.reconfig(config);
printjson(rs.config());
EOF
    fi

}

run_genny()
{
    job=$1
    name=$2

    rm -rf build/genny-metrics* &> /dev/null

    echo "Running $name ..."
    # ./scripts/genny run --workload-file $job --mongo-uri 'mongodb://localhost:27017'
    # ./scripts/genny run --workload-file $job --mongo-uri 'mongodb://md0:27017'
    ./run-genny workload -- -v debug run --workload-file $job  --mongo-uri 'mongodb://md0:27017'

    mv build/genny-metrics $metrics_dir/$name
    mv build/genny-metrics.csv $metrics_dir/$name/$name.csv
    ssh md0 "ls -l $db_dir/node1/db" > $metrics_dir/$name/$name.ls.out
    ssh md0 "~/bin/mongo --eval 'db.runCommand({collStats: \"Collection0\"})'" > $metrics_dir/$name/$name.collstats
}

emrcf_opt="--enableMajorityReadConcern true"
grow_count=10
kill_secondary=yes
plot=no
primary_restart=no
reconfig_secondary=no
export WIREDTIGER_CONFIG="" 
export wiredtiger_opts=""
# Parse command line arguments
while :; do
    case "$1" in
    -b)
        kill_secondary=no
        shift ;;
    -f)
        emrcf_opt="--enableMajorityReadConcern false"
        shift ;;
    -g)
        grow_count=$2
        shift ; shift ;;
    -m)
        metrics_dir=$2
        shift ; shift ;;
    -p)
        plot=yes
        gnuplot_cmd=`which gnuplot`
        if [ ! -x "$gnuplot_cmd" ]
        then
            echo "-p option requires gnuplot"
            exit 1
        fi
        shift ;;
    -n)
        primary_restart=yes
        shift ;;
    -r)
        reconfig_secondary=yes
        shift ;;
    -c)
        wiredtiger_opts="statistics=[all],statistics_log=(wait=1,json=true,on_close=true)"
        export WIREDTIGER_CONFIG="statistics=[all],statistics_log=(wait=1,json=true,on_close=true)" 
        shift ;;
    -*)
        usage ;;
     *)
        break ;;
    esac
done

        
populate=~/proj/eMRCfPopulate.yml
grow=~/proj/eMRCfGrow.yml
benchmark=~/proj/eMRCfBench.yml


populate=~/src/genny/dist/etc/genny/workloads/contrib/historystore/eMRCfPopulate.yml
grow=~/src/genny/dist/etc/genny/workloads/contrib/historystore/eMRCfGrow.yml
benchmark=~/src/genny/dist/etc/genny/workloads/contrib/historystore/eMRCfBench.yml

# Now we run the workload.

echo "Setting up PSA replica set ..."
mongo_opts="--setParameter enableFlowControl=false $emrcf_opt"
start_psa

# Genny prep
mkdir -p $metrics_dir &> /dev/null
cd $metrics_dir
metrics_dir=$PWD

cd $genny_dir

run_genny $populate Populate

if [ "$kill_secondary" = "yes" ]
then
    echo "Shutting down secondary node ..."
    ssh md1 "~/bin/mongod --dbpath $db_dir/node2/db --shutdown" &> /dev/null

fi

reconfig_votes $reconfig_secondary

# Let any delayed processing quiesce then run the benchmark
sleep 120
run_genny $benchmark Bench_initial

# Grow the history store
for X in $(seq 1 $grow_count)
do
    run_genny $grow Grow_$X
done

sleep 120
run_genny $benchmark Bench_final

if [ "$primary_restart" = "yes" ]
then
    echo "Restart primary"
    restart_primary    
else
    echo "Continue workload"

    # Let any delayed processing from the grow phase quiesce then re-run the benchmark
sleep 120
ssh md1 "~/bin/mongod --bind_ip_all --replSet rs --dbpath $db_dir/node2/db --logpath $db_dir/node2/db/mongod.log --port 27018 --fork $mongo_opts"
run_genny $benchmark Bench_catchup

# Copy additional data from run.
# cp -R $db_dir/node1/db/diagnostic.data $metrics_dir
# cp -R $db_dir/node1/db/mongod.log $metrics_dir

scp -r md0:$db_dir/node1/db/diagnostic.data $metrics_dir
scp -r md0:$db_dir/node1/db/mongod.log $metrics_dir

if [ "$plot" = "no" ]
then
    # Don't need to plot results.  We're done.
    exit 0
fi

cd $metrics_dir

# For each benchmark phase, we pull the relevant operations out of the CSV files and sort them
# to generate a CDF.  
#
# Note that the CSV files created by Genny capture per request latency in nanoseconds.
# We divide by 1000 and plot them in microseconds.
#
# WARNING:  Future versions of Genny won't provide this CSV metrics output.  The following
# code (and the -p option) will stop working at that point.

echo "Preparing plots..."
tmpfile=$(mktemp)
for RUN in initial final catchup
do
    mkdir $RUN &> /dev/null
    for PHASE in InsertPhase UpdateHeavyPhase ReadMostlyPhase DeletePhase
    do
        echo "    Processing $RUN/$PHASE..."
        grep "^[0-9].*$PHASE.*One" Bench_$RUN/Bench_$RUN.csv > $tmpfile
        count=$(wc -l $tmpfile | awk '{print $1}')
        count=$(($count / 100))
        cat $tmpfile | sed -e 's/,/ /g' | awk '{print $5}' | sort -n | \
            awk "BEGIN {n = 1} {print \$1/1000, n/$count; n++}" > $RUN/$PHASE
    done
done
rm $tmpfile

# Draw some pictures.  At best this provides a quick look at the test results.
# If anything interesting or unusual happened, additional analysis will probably be required.
# For example, we scale the plots assuming that request latencies are <= 2ms.
gnuplot << GPLOT_INSERT_PHASE
    set style data lines
    set xrange [0:2000]
    set xlabel "Request latency (microsecs)"
    set yrange [0:100]
    set ylabel "CDF"
    set key bottom right
    set title "Insert Phase: Request latency distribution (remote / $grow_count / $emrcf_opt)"
    set term jpeg linewidth 2 size 1280,960 font "arial,20.0"
    set output "insert.jpg"
    plot "initial/InsertPhase" title "Before", "final/InsertPhase" title "After", "catchup/InsertPhase" title "Catchup"
GPLOT_INSERT_PHASE

gnuplot << GPLOT_UPDATE_HEAVY_PHASE
    set style data lines
    set xrange [0:2000]
    set xlabel "Request latency (microsecs)"
    set yrange [0:100]
    set ylabel "CDF"
    set key bottom right
    set title "Update Heavy Phase: Request latency distribution (remote / $grow_count / $emrcf_opt)"
    set term jpeg linewidth 2 size 1280,960 font "arial,20.0"
    set output "update_heavy.jpg"
    plot "initial/UpdateHeavyPhase" title "Before", "final/UpdateHeavyPhase" title "After", "catchup/UpdateHeavyPhase" title "Catchup"
GPLOT_UPDATE_HEAVY_PHASE

gnuplot << GPLOT_READ_MOSTLY_PHASE
    set style data lines
    set xrange [0:2000]
    set xlabel "Request latency (microsecs)"
    set yrange [0:100]
    set ylabel "CDF"
    set key bottom right
    set title "Read Mostly Phase: Request latency distribution (remote / $grow_count / $emrcf_opt)"
    set term jpeg linewidth 2 size 1280,960 font "arial,20.0"
    set output "read_mostly.jpg"
    plot "initial/ReadMostlyPhase" title "Before", "final/ReadMostlyPhase" title "After", "catchup/ReadMostlyPhase" title "Catchup"
GPLOT_READ_MOSTLY_PHASE

gnuplot << GPLOT_DELETE_PHASE
    set style data lines
    set xrange [0:2000]
    set xlabel "Request latency (microsecs)"
    set yrange [0:100]
    set ylabel "CDF"
    set key bottom right
    set title "Delete Phase: Request latency distribution (remote / $grow_count / $emrcf_opt)"
    set term jpeg linewidth 2 size 1280,960 font "arial,20.0"
    set output "delete.jpg"
    plot "initial/DeletePhase" title "Before", "final/DeletePhase" title "After", "catchup/DeletePhase" title "Catchup"
GPLOT_DELETE_PHASE
fi
