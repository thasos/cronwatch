#!/bin/bash
function setDefaultVars() {
    logfile="/var/log/syslog"
    filterTerm="all"
    status="all"
    debug=false
    timestamp=false
    noTruncate=false
}

function parseArgs() {
    usage="Usage : $0 -f [logfile] -F [filter_term] -s [status]
Options :
    -f, --file                      logfile to parse (can be several)
    -0, --ok                        (not implemented yet) filter failed cronjobs
    -1, --ko                        (not implemented yet) filter successfull cronjobs
    -F, --filter                    filter (user, pid, command...) specific cronjobs
    -t, --timestamp                 display dates and duration in timestamp and second format
    -T, --no-truncate             don't truncate command line                  

    -d, --debug                     display debug infos
    -h, --help                      display help message

Example :

    $0 -f /var/log/syslog* -u root --ko
"
    # long options transformation
    for arg in "$@"; do
        shift
        case "$arg" in
            "--file")		 set -- "$@" "-f" ;;
            "--filter") 	 set -- "$@" "-F" ;;
            "--ok")	    	 set -- "$@" "-0" ;;
            "--ko")		     set -- "$@" "-1" ;;
            "--timestamp")   set -- "$@" "-t" ;;
            "--no-truncate") set -- "$@" "-T" ;;
            "--debug")		 set -- "$@" "-d" ;;
            "--help")		 set -- "$@" "-h" ;;
            *)			     set -- "$@" "$arg"
        esac
    done

    while getopts "f:F::01hdtT" opt ; do
        case $opt in
            f) logfile="$OPTARG" ;;
            F) filterTerm="$OPTARG" ;;
            0) status="OK" ;;
            1) status="KO" ;;
            t) timestamp=true ;;
            T) noTruncate=true ;;
            d) debug=true ;;
            h) echo "$usage" && exit 0 ;;
            /?) echo "$usage" && exit 0 ;;
        esac
    done

    # list vars in debug mode
    $debug && echo "debug: logfile = $logfile, filterTerm = $filterTerm,  status = $status, debug = $debug"
}

function checkFilesRights() {
    [[ ! -f "$logfile" ]] && echo "error : file $logfile not found" && exit 255
    $debug && echo -n "debug: logfile $logfile exists : " && ls -l "$logfile"
    # TODO check, limit filesize ?
    if [[ ! -r "$logfile" ]]
    then
        # sudo proposal
        sudo=""
        echo "warning : cannot read $logfile, did you forget sudo ? [Y/n]"
        read -r sudoChoice
        case "$sudoChoice" in
            "") sudo="sudo" ;;
            Y) sudo="sudo" ;;
            y) sudo="sudo" ;;
            yes) sudo="sudo" ;;
            *) echo "error : can't read file(s)" && exit 255 ;;
        esac
    fi
}

function rawFilterLogs() {
    # TODO remove tail
    allLogs="$($sudo zgrep " CRON" "$logfile" | tail -100)"

    # TODO parse before filter ?

    # filterTerm filtering
    if [ "$filterTerm" != "all" ]
    then
        filterTermLogs="$(echo "$allLogs" | grep -E "($filterTerm)")"
        logsToParse="$filterTermLogs"
    else
        logsToParse="$allLogs"
    fi
}

function formatValue() {
    local rawValue="$1"
    local columnSize="$2"
    local formattedValue
    formattedValue="$(echo "$rawValue" | cut -c -"${columnSize}")"
    local missingChar=$(( columnSize - ${#formattedValue} ))
    if [[ "$missingChar" -eq 0 ]]; then
        echo "$formattedValue"
    else
        # add spaces char if value lenght too short
        echo -n "$formattedValue"
        for (( i = 0; i < missingChar; i++ )); do
          echo -n " "
        done
    fi
}

function formatDateValue() {
    date -d @"$1" +"%F %X"
}

function jobDurationFormat() {
    local duration=$1
    local dayCount=$((duration/60/60/24))
    local hourCount=$((duration/60/60%24))
    local minuteCount=$((duration/60%60))
    local secondCount=$((duration%60))

    if (( dayCount > 0 )); then
        jobDurationLine1="$dayCount days"
    elif (( hourCount > 0 )); then
        jobDurationLine1="$hourCount hours"
        jobDurationLine2="$minuteCount minutes"
    elif (( minuteCount > 0 )); then
        jobDurationLine1="$minuteCount minutes"
        jobDurationLine2="$secondCount seconds"
    else
        jobDurationLine1="$secondCount seconds"
        jobDurationLine2=""
    fi
    jobDurationLine1="$(formatValue "$jobDurationLine1" 10)"
    jobDurationLine2="$(formatValue "$jobDurationLine2" 10)"
}

function parseLogs() {
    # shellcheck disable=SC1078
    # shellcheck disable=SC1079

    # logs loop
    # TODO rework algo to merge zgreps
    while read -r line
    do
        # data split
        IFS=' ' read -r -a splitted_line <<< "$line"

        # parsing
        jobStartDate="$(date -d"${splitted_line[0]} ${splitted_line[1]} ${splitted_line[2]}" +%s)"
        # shellcheck disable=SC2001        # multiline grouped, too complicated to read if i do that
        {
            jobPID1="$( echo "${splitted_line[4]}" | sed "s/^CRON\\[\\(.*\\)\\]:/\\1/g" )"
            jobPID2="$( echo "${splitted_line[7]}" | sed "s/^(\\[\\(.*\\)\\]/\\1/g" )"     # TODO rename grandchild ?
            jobUser="$( echo "${splitted_line[5]}" | sed "s/^(\\(.*\\))$/\\1/g" )"
            jobCommandLine="$( echo "${splitted_line[*]:8}" | sed "s/)$//g")"
        }
        $debug && echo -e "debug: cmd : $jobCommandLine\\ndebug: pids : $jobPID1 and $jobPID2, user $jobUser"

        # shellcheck disable=SC2002      # wc output not customizable witch option, so...
        pidMaxLenght="$(cat /proc/sys/kernel/pid_max | wc -c)"
        jobPID1Formatted="$(formatValue "$jobPID1" "$pidMaxLenght")"
        jobUserFormatted="$(formatValue "$jobUser" 7)"
        if ( ! $noTruncate ); then
            jobCommandLine="$(formatValue "$jobCommandLine" 35)"
        fi

        # find job end date with pid1
        jobEndDate="$(date -d "$($sudo zgrep "\\[$jobPID1\\]" "$logfile" | grep "END" | awk '{ print $1 " " $2 " " $3 }')" +%s)"

        # deduct job duration
        jobDuration="$(( jobEndDate - jobStartDate ))"

        # dates/duration in human readable format
        if ( ! "$timestamp" ); then
            jobStartDate="$(formatDateValue "$jobStartDate")"
            jobEndDate="$(formatDateValue "$jobEndDate")"
            jobDurationFormat "$jobDuration"
        fi

        $debug && echo "debug: date = $jobStartDate, end_date : $jobEndDate, duration : $jobDuration"

        # find if job failed
        failLog="$($sudo zgrep "\\[$jobPID1\\]" "$logfile" | grep "failed with exit status")"
        if [[ -z "$failLog" ]]
        then
            jobStatus="\\e[32mOK\\e[0m"
            $debug && echo -e "debug: status : $jobStatus"
            logsToStatus="${logsToStatus}"
        else
            jobStatus="\\e[31mKO\\e[0m"
            # extract fail log info
            # shellcheck disable=SC2001
            jobStatusCode="$( echo "$failLog" | sed "s/.*with exit status \\(.*\\))$/\\1/g" )"
            # shellcheck disable=SC2001
            jobGrandchild="$( echo "$failLog" | sed "s/.*grandchild #\\(.*\\) failed with exit status.*/\\1/g" )"
            $debug && echo "debug: status : $jobStatus (exit status : $jobStatusCode, jobGrandchild : $jobGrandchild)"
            logsToStatus="${logsToStatus}"
        fi
 
        # spaces are importants
        # TODO cut cmd line with terminal size, and print the rest in 2nd line
        logsToStatus="${logsToStatus}  $jobPID1Formatted   $jobUserFormatted   $jobStatus   started $jobStartDate   $jobDurationLine1   $jobCommandLine\n"
        logsToStatus="${logsToStatus}                             ended $jobEndDate   $jobDurationLine2\n"
        logsToStatus="${logsToStatus}\\e[0m\n"

    # end loop, with all start (CMD) logs in input
    done < <(echo "$logsToParse" | grep " CMD ")
}

function statusFilter() {
    # spaces are importants
    echo -e "  job pid    user      st   dates                         duration     cmd\n"
    echo -e "$logsToStatus"
}

setDefaultVars
parseArgs "$@"
checkFilesRights
rawFilterLogs
parseLogs
statusFilter
