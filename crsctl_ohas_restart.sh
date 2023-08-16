#!/bin/bash
################################################################################
#Script          crsctl_ohas_restart.sh
################################################################################
#Description     This script will do the following:
#
#                STOP
#                  1) Check to see if OHAS is running
#                  2) Determine if RAC or Standalone with HAS
#                  3) Save information to be used int startup of HAS, such as
#                     GRID_HOME and type for service running
#                  3) run srvctl_oracle_db_restart.sh stop to stop all dbs
#                  4) run crsctl stop has
#                START
#                  1) Read saved stop information, to gather startup needs
#                  2) Run crsctl start has
#                  3) Run srvctl_oracle_db_restart.sh start
#
#Parameters      1) stop/start
#
#Override Vars   You can override the following variables by creating the file
#                ctl_ohas_restart.env and including the varaibles you want
#                to override
#
#                export LOG_PATH="/var/oracle/export/updown/log"
#                export STATE_PATH="/var/oracle/export/updown/state"
#                export EMAIL_LIST='#MMCGLMarshAMSIDBAOracle@mercer.com'
#                export LOG_PATH="${PROGRAM_SCRIPT_DIRECTORY}/log"
#                export STATE_PATH="${PROGRAM_SCRIPT_DIRECTORY}/state"
#                export OHAS_PROP_FILE="ohas_stop_properties.ini"
#                export BLACKOUT_COMMENT="#BLKOUT-"
#                export MAX_DB_START_TIMEOUT=300
#                export MAX_DB_STOP_TIMEOUT=300
#                export CHECK_TIMEOUT=300
#                export FIND_HAS_TIMEOUT=60
#                export SLEEP_SECONDS=5
#
#
#Example         srvctl_oracle_db_restart stop
#                srvctl_oracle_db_restart start
#
#Modifications
#
#2019/05/20      check if user is root and start and stop with out sudo:
#                    $ORACLE_HOME/bin/crsctl stop has -f
#                    $ORACLE_HOME/bin/crsctl start has -f
#                  or use sudo if not root
#                    sudo $ORACLE_HOME/bin/crsctl stop has -f
#                    sudo $ORACLE_HOME/bin/crsctl start has
#
#2019/06/07      Added some error checking and chmod 777
#
#2019/07/16      Modified the script to run srvctl_oracle_db_restart.sh if the HAS
#                has been already started
#
#2019/08/20      Fixed issue getting the oracle grid
#
#Author          datavail
#Date            2019/05/13
################################################################################

PROGRAM_NAME=$0
COMMAND_LINE="$0 $@"

export PROGRAM_SCRIPT_DIRECTORY=$(cd $(dirname $0); echo $PWD)
cd $PROGRAM_SCRIPT_DIRECTORY

LOG_PATH="/var/oracle/export/updown/log"
STATE_PATH="/var/oracle/export/updown/state"
EMAIL_LIST='#MMCGLMarshAMSIDBAOracle@mercer.com,#MMCMarshGITO-GSDSharedServices-NAM-DBA@hub.wmmercer.com'

OHAS_PROP_FILE="ohas_stop_properties.ini"
BLACKOUT_COMMENT="#BLKOUT-"
MAX_DB_START_TIMEOUT=300
MAX_DB_STOP_TIMEOUT=300
CHECK_TIMEOUT=300
FIND_HAS_TIMEOUT=60
SLEEP_SECONDS=5

#
## Override the above variables if file exist
#
if [ -e "crsctl_ohas_restart.env" ]; then
    source crsctl_ohas_restart.env
fi


STATE_ARCH_PATH="${STATE_PATH}/archive"
ORIGINAL_PATH=$PATH
ORIGINAL_LD_LIBRARY_PATH=$LD_LIBRARY_PATH
ORIGINAL_IFS=$IFS
RUN_TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
GRID_ORACLE_HOME=''
AGENT_ORACLE_HOME=''
NODENAME=''
LOG_FILE=''
RUNNING_SERVICE='NONE'
RUNNING_AS_USER="$(whoami)"

clear

#==============================================================================#
get_log_timestamp()
#==============================================================================#
{
echo "$(date +"%Y-%m-%d %H:%M:%S")"
}
#==============================================================================#
create_log_file()
#==============================================================================#
{
#
## Create the logfile from the script name
## Touch the file to create it
#
    # passed in start or stop
    local start_stop_option=$1
    # remove path from the program
    local script_filename_wo_path=$(basename -- "$PROGRAM_NAME")
    # remove path extenstion from
    local script_filename_wo_extn=${script_filename_wo_path%.*}
    # build logfile name as "script_name_timestamp_start/stop.log"
    local logfile="${script_filename_wo_extn}_${RUN_TIMESTAMP}_$start_stop_option.log"
    # Update the global variable with the fully path logfilename
    LOG_FILE="$LOG_PATH/$logfile"

    touch $LOG_FILE
    if [ $? -ne 0 ]; then
        echo "ERROR: unable to create $LOG_FILE"
        exit 1
    fi

    chmod 777 $LOG_FILE
}
#==============================================================================#
log()
#==============================================================================#
{
    echo "$(get_log_timestamp) $1" | tee -a $LOG_FILE
}
#==============================================================================#
log_info()
#==============================================================================#
{
    log " INFO: $1"
}
#==============================================================================#
log_warn()
#==============================================================================#
{
    log " WARN: $1"
}
#==============================================================================#
log_error()
#==============================================================================#
{
    log "ERROR: $1"
}
#==============================================================================#
log_header()
#==============================================================================#
{
    log_info ""
    log_info "====================================================================="
    log_info "$1"
    log_info "====================================================================="
}
#==============================================================================#
log_info_output()
#==============================================================================#
{
    local l_output="$1"
    while read line
    do
        log_info "$line"
    done <<< "$(echo -e "$l_output")"
}
#==============================================================================#
log_error_output()
#==============================================================================#
{
    local l_output="$1"
    while read line
    do
        log_error "$line"
    done <<< "$(echo -e "$l_output")"
}
#==============================================================================#
error_exit()
#==============================================================================#
{
    local l_error_subject=$1

    mail -s "$PROGRAM_NAME failed: $l_error_subject" "$EMAIL_LIST" < $LOG_FILE

    exit 1
}
#==============================================================================#
warn_email()
#==============================================================================#
{
    local l_error_subject=$1

    mail -s "$PROGRAM_NAME failed: $l_error_subject" "$EMAIL_LIST" < $LOG_FILE
}
#==============================================================================#
set_oracle_home()
#==============================================================================#
{
    export ORACLE_HOME=$1
    export PATH=$ORACLE_HOME/bin:$ORIGINAL_PATH
    export LD_LIBRAY_PATH=$ORACLE_HOME/lib:$ORIGINAL_LD_LIBRARY_PATH
    return
}
#==============================================================================#
set_oracle_home_to_grid_home()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() - Enviroment setup for GRID_ORACLE_HOME"
    set_oracle_home $GRID_ORACLE_HOME
    log_info "       ORACLE_HOME: $ORACLE_HOME"
    log_info "              PATH: $PATH"
    log_info "    LD_LIBRAY_PATH: $LD_LIBRAY_PATH"
}
#==============================================================================#
get_high_availability_home()
#==============================================================================#
{
    local has_process=$1

    echo $has_process|awk '{for(i=1;i<=NF;i++){if ($i ~ /ohasd.bin/){print $i}}}'| sed 's/\/bin\/ohasd\.bin.*$//'

    return
}
#==============================================================================#
log_output()
#==============================================================================#
{
    IFS=$'\n' OUTPUT_LINES=($1)
    for line in "${OUTPUT_LINES[@]}"
    do
        log_info "$line"
    done

    IFS=$ORIGINAL_IFS
}
#==============================================================================#
ohas_service_already_running()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    log_info "Running: ps -ef|grep ohasd.bin|grep -v grep"
    HAS_PROCESS=`ps -ef|grep ohasd.bin|grep -v grep`
    if [ $? -eq 0 ]; then
        log_info "Output: $HAS_PROCESS"
        log_info ""
        log_info "ohas process already running"
        return 0
    else
        log_info "ohas process is not running"
        return 1
    fi
}
#==============================================================================#
set_type_of_running_service()
#==============================================================================#
{
    HAS_PROCESS=`ps -ef|grep ohasd.bin|grep -v grep`
    if [ $? -eq 0 ]; then
        GRID_ORACLE_HOME=$(get_high_availability_home "$HAS_PROCESS")
        set_oracle_home_to_grid_home
        log_info "OHAS is running on server"
        log_header "${FUNCNAME[0]}()"
#       local l_cluster_check
#       l_cluster_check="$(crsctl check cluster 2> /dev/null)"
#       if [ $? -eq 0 ]; then
#           log_info ""
#           log_info "Server is running on a rac cluster"
#           log_output "$l_cluster_check"
#           RUNNING_SERVICE="RAC"
#       else
#           local l_cluster_has
#           l_cluster_has="$(crsctl check has)"
#           if [ $? -eq 0 ]; then
#               log_info ""
#               log_info "Server is running standalone with OHAS service"
#               log_output "$l_cluster_has"
#               RUNNING_SERVICE="OHAS"
#           fi
#       fi
        local l_cluster_has
        l_cluster_has="$(crsctl check has)"
        if [ $? -eq 0 ]; then
            log_info ""
            log_info "Server is running standalone with OHAS service"
            log_output "$l_cluster_has"
            RUNNING_SERVICE="OHAS"
        fi
    else
        log_header "${FUNCNAME[0]}()"
        log_info "Server is running OHAS service"
        RUNNING_SERVICE="NO-HAS"
    fi

    log_info ""
    log_info "RUNNING_SERVICE: $RUNNING_SERVICE"

    return
}
#==============================================================================#
confirm_or_create_path()
#==============================================================================#
{
    local l_path=$1
    if [ ! -d "$l_path" ]; then
        mkdir -p $l_path
        if [ $? -eq 0 ]; then
            echo "Directory ${l_path} created"
        else
            echo "ERROR: Directory ${l_path} failed to create."
            echo "       Exiting script"
            exit 1
        fi
    fi

    chmod 777 $l_path
}
#==============================================================================#
head_line()
#==============================================================================#
{
    echo $(seq 1 $1 | sed 's/.*/=/' | tr -d '\n')
    return
}
#==============================================================================#
wait_if_etc_initd_is_running_the_startup()
#==============================================================================#
{
#
## This function will loop for time specified in CHECK_TIMEOUT
## The reason we are looping is because on startup the OHAS service take time
## to complete get started.  So it will loop on til ig get at
## CRS-4638: Oracle High Availability Services is online,
## or times out.
##
## We can not start oracle homes until the CRS is up
##
## FYI you will see it hang for a while, once it is up, but not completely
## It appears after that hang, it will say it is online
#
    log_header "${FUNCNAME[0]}() - crsctl check has"

    let l_end_time=$(date +%s)+$CHECK_TIMEOUT
    log_info "Waiting for Oracle High Availability Services to come online"
    log_info "   FYI if the services is coming online, the crsctl check has"
    log_info "       will wait for it to finish, so it may appear to be sleeping"
    log_info "       for a longer time."
    while true
    do
        log_info "$(crsctl check has)"
        if [[ "$(crsctl check has)" == CRS-4638:* ]]; then
            log_info ""
            log_info "CRS-4638: Oracle High Availability Services is online"
            return
        fi
        if [ $(date +%s) -gt $l_end_time ]; then
            log_error ""
            log_error "High Availiablity service not start with in time"
            log_error "    Exiting startup"
            error_exit "High Availiablity service not start with in time"
        fi
        log_info "Oracle High Availability Services is not online: Waiting for another 5 seconds"
        sleep $SLEEP_SECONDS
    done
}
#==============================================================================#
wait_rac_cluster_to_come_online()
#==============================================================================#
{
#
    log_header "${FUNCNAME[0]}()"

    let l_end_time=$(date +%s)+$CHECK_TIMEOUT
    log_info "Waiting for crstl check cluster to show online."
    log_info "Looking for 'CRS-4537: Cluster Ready Services is online'"
    while true
    do
        crsctl check cluster|grep CRS-4537: >/dev/null
        if [ $? -eq 0 ]; then
            log_info ""
            log_info "CRS-4537: Cluster Ready Services is online"
            return
        fi
        if [ $(date +%s) -gt $l_end_time ]; then
            log_error ""
            log_error "Cluster has not start with in $CHECK_TIMEOUT seconds"
            log_error "    Exiting startup"
            error_exit "Cluster has not start with in $CHECK_TIMEOUT seconds"
        fi
        log_info "Oracle Cluster Ready Service is not online: Waiting for another $SLEEP_SECONDS seconds"
        sleep $SLEEP_SECONDS
    done
}

#==============================================================================#
set_running_service_from_ohas_properties ()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    local l_ohas_properties_file="${STATE_PATH}/${OHAS_PROP_FILE}"

    log_info ""
    log_info "Checking if $l_ohas_properties_file properties file exist"
    if [ ! -e "$l_ohas_properties_file" ]; then
        log_error "$l_ohas_properties_file does not exist"
        log_error "Unable to determine previous shutdown state"
        error_exit "Unable to determine previous shutdown state"
    fi
    log_info "Reading properties $l_ohas_properties_file"
    while read -r line
    do
        IFS== read -r key value <<<"$line"
        case  "$key" in
            GRID_ORACLE_HOME)
                GRID_ORACLE_HOME=$value
                log_info "GRID_ORACLE_HOME = $GRID_ORACLE_HOME"
                ;;
            RUNNING_SERVICE)
                RUNNING_SERVICE=$value
                log_info "RUNNING_SERVICE = $RUNNING_SERVICE"
                ;;
            *)
                log_warn "Error parsing $l_ohas_properties_file"
                log_warn "   $key is unknown"
                ;;
        esac
    done <"$l_ohas_properties_file"

    if [ -z "$GRID_ORACLE_HOME" ]; then
        log_error "GRID_ORACLE_HOME variable not set.  Exiting"
        error_exit "GRID_ORACLE_HOME variable not set.  Exiting"
    fi
    if [ -z "$RUNNING_SERVICE" ]; then
        log_error "RUNNING_SERVICE variable not set.  Exiting"
        error_exit "RUNNING_SERVICE variable not set.  Exiting"
    fi

    return
}
#==============================================================================#
write_ohas_properties ()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    log_info "This is written on stop, so startup knows what configuration to start"
    log_info

    local l_ohas_properties_file="${STATE_PATH}/${OHAS_PROP_FILE}"
    local l_ohas_properties_arch="${STATE_ARCH_PATH}/${OHAS_PROP_FILE}_${RUN_TIMESTAMP}"

    log_info "Creating properties file $l_ohas_properties_file"
    log_info "Writing \"GRID_ORACLE_HOME=${GRID_ORACLE_HOME}\" to $l_ohas_properties_file"

    echo "GRID_ORACLE_HOME=${GRID_ORACLE_HOME}" > $l_ohas_properties_file
    if [ $? -ne 0 ]; then
        log_error "Unable to write ohas properties to $l_ohas_properties_file"
        log_error "There will be issue in startup"
        return
    fi
    log_info "Writing \"RUNNING_SERVICE=${RUNNING_SERVICE}\" to $l_ohas_properties_file"
    echo "RUNNING_SERVICE=${RUNNING_SERVICE}" >> $l_ohas_properties_file
    chmod 777 $l_ohas_properties_file

    cp $l_ohas_properties_file $l_ohas_properties_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive ohas properties files"
        log_error "cp $l_ohas_properties_file $l_ohas_properties_arch failed"
    fi
    chmod 777 $l_ohas_properties_arch

    return
}
#==============================================================================#
usage ()
#==============================================================================#
{
    echo "usage: $PROGRAM_NAME (start|stop)"
    exit 1
}
#==============================================================================#
stop_stack()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
#
## Find out if running RAC, OHAS or NO-OHAS
#
    set_type_of_running_service

    case  "$RUNNING_SERVICE" in
#       RAC)
#           log_info
#           log_info "Stopping RAC"
#           write_ohas_properties
#           log_info
#           log_info "Running \"./srvctl_oracle_db_restart.sh stop\" to stop all databases"
#          ./srvctl_oracle_db_restart.sh stop
#           log_info
#           log_info "Running \"sudo $ORACLE_HOME/bin/crsctl stop has -f\" to stop Oracle High Avil Service"
#           log_info_output "$(sudo $ORACLE_HOME/bin/crsctl stop has -f)"
#           ;;
        OHAS)
            log_info
            log_info "Stopping HAS"
            write_ohas_properties
            log_info
            if [ "$RUNNING_AS_USER" == "root" ]; then
                log_info "Running \"/bin/su \"./srvctl_oracle_db_restart.sh stop\" oracle\" to start all databases"
                /bin/su -c './srvctl_oracle_db_restart.sh stop' oracle
                log_info
                log_info "Running \"$ORACLE_HOME/bin/crsctl stop has -f\" to stop Oracle High Avail Service"
                $ORACLE_HOME/bin/crsctl stop has -f | tee -a $LOG_FILE
                rtn="${PIPESTATUS[0]}"
                if [ $rtn -ne 0 ]; then
                    log_error ""
                    log_error "RETURN: $rtn"
                    error_exit "crsctl stop has -f failed"
                fi
            else
                log_info "Running \"./srvctl_oracle_db_restart.sh stop\" to stop all databases"
                ./srvctl_oracle_db_restart.sh stop
                log_info
                log_info "Running \"sudo $ORACLE_HOME/bin/crsctl stop has -f\" to stop Oracle High Avail Service"
                sudo $ORACLE_HOME/bin/crsctl stop has -f | tee -a $LOG_FILE
                rtn="${PIPESTATUS[0]}"
                if [ $rtn -ne 0 ]; then
                    log_error ""
                    log_error "RETURN: $rtn"
                    error_exit "sudo crsctl stop has -f failed"
                fi
            fi
            ;;
        NO-HAS)
            log_info "Stopping with no HAS"
            error_exit "Error no HAS running on server"
            ;;
        *)
            log_error "Unable to determine the server setup"
            ;;
    esac
}
#==============================================================================#
start_stack()
#==============================================================================#
{
#
    log_header "${FUNCNAME[0]}()"
    set_running_service_from_ohas_properties

    case  "$RUNNING_SERVICE" in
#       RAC)
#           if ohas_service_already_running; then
#               log_info "Skipping OHAS start"
#           else
#               log_info "Starting RAC"
#               set_oracle_home_to_grid_home
#               log_info
#               log_info "Running \"sudo $ORACLE_HOME/bin/crsctl start has\" to start High Avil Service"
#               log_info_output "$(sudo $ORACLE_HOME/bin/crsctl start has)"
#               log_info
#           fi
#           log_info "Running \"./srvctl_oracle_db_restart.sh start\" to start all databases"
#           ./srvctl_oracle_db_restart.sh start
#           ;;
        OHAS)
            if ohas_service_already_running; then
                log_info "Skipping OHAS start"
            else
                log_info "Starting HAS"
                set_oracle_home_to_grid_home
                log_info
                if [ "$RUNNING_AS_USER" == "root" ]; then
                    log_info "Running \"$ORACLE_HOME/bin/crsctl start has\" to start Oracle High Avail Service"
                    $ORACLE_HOME/bin/crsctl start has | tee -a $LOG_FILE
                    rtn="${PIPESTATUS[0]}"
                    if [ $rtn -ne 0 ]; then
                        log_error ""
                        log_error "RETURN: $rtn"
                        error_exit "crsctl start has failed"
                    fi
#                    log_info
#                    log_info "Running \"/bin/su \"./srvctl_oracle_db_restart.sh start\" oracle\" to start all databases"
#                    /bin/su -c './srvctl_oracle_db_restart.sh start' oracle
                else
                    log_info "Running \"sudo $ORACLE_HOME/bin/crsctl start has\" to start Oracle High Avail Service"
                    sudo $ORACLE_HOME/bin/crsctl start has | tee -a $LOG_FILE
                    rtn="${PIPESTATUS[0]}"
                    if [ $rtn -ne 0 ]; then
                        log_error ""
                        log_error "RETURN: $rtn"
                        error_exit "sudo crsctl start has failed"
                    fi
#                    log_info
#                    log_info "Running \"./srvctl_oracle_db_restart.sh start\" to start all databases"
#                    ./srvctl_oracle_db_restart.sh start
                fi
            fi

            if [ "$RUNNING_AS_USER" == "root" ]; then
                log_info
                log_info "Running \"/bin/su \"./srvctl_oracle_db_restart.sh start\" oracle\" to start all databases"
                /bin/su -c './srvctl_oracle_db_restart.sh start' oracle
            else
                log_info
                log_info "Running \"./srvctl_oracle_db_restart.sh start\" to start all databases"
                ./srvctl_oracle_db_restart.sh start
            fi
            ;;
        NO-HAS)
            log_info "Starting with no HAS"
            error_exit "Error no HAS running on server"
            ;;
        *)
            log_error "Unable to determine the server setup"
            ;;
    esac
}
#==============================================================================#
# Main Sections
#==============================================================================#
confirm_or_create_path $LOG_PATH
confirm_or_create_path $STATE_PATH
confirm_or_create_path $STATE_ARCH_PATH
create_log_file $1

log_info "RUNNING: $COMMAND_LINE"
log_info "HOSTNAME: `hostname`"
log_info ""
log_info "LOGFILE: $LOG_FILE"
log_info ""
log_info "Script running as user: $RUNNING_AS_USER"
log_info ""

case  "$1" in
    start)
        start_stack
        ;;
    stop)
        stop_stack
        ;;
    *)
        usage
        ;;
esac


