#!/bin/bash
################################################################################
#Script          srvctl_oracle_db_restart.sh
################################################################################
#Description     This script will do the following:
#
#                STOP
#                  1) blackout the server in the OMS
#                  2) comment out the lines in the crontab
#                  3) capture the crsctl stat res -t (to compare on start up)
#                  4) stop all databases
#                  5) stop all listeners if not using OHAS
#                START
#                  1) start all listeners if not using OHAS
#                  2) start all database that were shutdown in the stop process
#                  3) capture the crsctl stat res -t
#                  4) compare crsctl stat res with the previous stop process
#                     to make sure everything is running.
#
#Parameters      1) stop/start/start_blackout/stop_blackout
#
#Override Vars   You can override the following variables by creating the file
#                srvctl_oracle_db_restart.env and including the varaibles you want
#                to override
#
#                export LOG_PATH="/var/oracle/export/updown/log"
#                export STATE_PATH="/var/oracle/export/updown/state"
#                export CRSCTL_STOP_STATUS_FILE="crsctl_stop_resource_status.rpt"
#                export CRSCTL_START_STATUS_FILE="crsctl_start_resource_status.rpt"
#                export SRVCTL_START_FILE="srvctl_start_file.cmd"
#                export NOHAS_START_FILE="sqlplus_start_database.ini"
#                export LISTENER_START_FILE="listener_start_database.ini"
#                export BLACKOUT_COMMENT="#BLKOUT-"
#                export MAX_DB_START_TIMEOUT=300
#                export MAX_DB_STOP_TIMEOUT=300
#                export CHECK_TIMEOUT=300
#                export FIND_HAS_TIMEOUT=60
#                export SLEEP_SECONDS=5
#                export EMAIL_LIST='#MMCGLMarshAMSIDBAOracle@mercer.com'
#
#
#Example         srvctl_oracle_db_restart.sh stop
#                srvctl_oracle_db_restart.sh start
#                srvctl_oracle_db_restart.sh start_blackout
#                srvctl_oracle_db_restart.sh stop_blackout
#
#Modification
#
#2019/05/20      Added parameter to start_blackout/stop_blackout
#
#2019/05/22      Added find_oratab function to set oratab locations
#                Updated awk command to have the -F field deliminator to work 
#                  with Solaris
#                Fixed basename syntax to comply with Solaris.  This address 
#                  logfile name formating issues
#                Updated get_running_srvctl_databases to use the database home
#                  before running $l_database_home/srvctl status database -d
#
#2019/05/23      Added logic to use sqlplus shutdown if HAS is not running on the server
#
#
#2019/06/07      Added some error checking and chmod 777
#                Addes emctl start agent
#
#2019/07/16      Fixed agent black out to user $ORATAB variable to find oratab
#
#2019/08/20      Fixed issue getting the oracle grid 
#
#2019/08/20      Changed the crsctl stat res -t to only look at databases and listeners
#                for comparing aftert startup
#
#2019/09/13      Fixed write_sqlplus_start_properties to no overwrite the properties file
#                in the loop over databases
#                Added logic for NOHAS to stop and start ASM
#
#2019/09/19      Added /usr/local/bin to $PATH in beginning of script so it can use . oraenv
#                Fixed issue with ASM startup by forcing it to use . oraenv
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

CRSCTL_STOP_STATUS_FILE="crsctl_stop_resource_status.rpt"
CRSCTL_START_STATUS_FILE="crsctl_start_resource_status.rpt"
SRVCTL_START_FILE="srvctl_start_file.cmd"
NOHAS_START_FILE="nohas_start_database.ini"
NOHAS_STOP_STATUS_FILE="nohas_stop_resource_status.rpt"
NOHAS_START_STATUS_FILE="nohas_start_resource_status.rpt"
LISTENER_START_FILE="listener_start_database.ini"
ASM_START_FILE="asm_start_instance_ini"
RUNNING_SERVICE_FILE="running_service_file.ini"
BLACKOUT_COMMENT="#BLKOUT-"
MAX_DB_START_TIMEOUT=300
MAX_DB_STOP_TIMEOUT=300
CHECK_TIMEOUT=300
FIND_HAS_TIMEOUT=60
SLEEP_SECONDS=5
ORATAB=""
EMAIL_LIST='#MMCGLMarshAMSIDBAOracle@mercer.com'

#
## Override the above variables if file exist
#
if [ -e "srvctl_oracle_db_restart.env" ]; then
    source srvctl_oracle_db_restart.env
fi

echo $LOG_PATH
echo $STATE_PATH
echo $EMAIL_LIST
#
## Add /usr/local/bin to path.  Needed for running .oraenv
#
PATH=/usr/local/bin:$PATH

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
HOSTNAME="$(hostname)"

#
## Get OS platform you are running on
#
#PLATFORM=`/bin/uname`

declare -a PMON_ARRAY
declare -a PMON_NO_ORATAB_ARRAY
declare -a PMON_YES_ORATAB_ARRAY
declare -a OHOME_ARRAY
declare -a SRVCTL_INST_ARRAY
declare -a SRVCTL_DB_ARRAY

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
    local script_filename_wo_path=$(basename  "$PROGRAM_NAME")
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
    #echo "$1" | tee -a $LOG_FILE
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
    log ""
    log "====================================================================="
    log "$1"
    log "====================================================================="
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
log_warn_output()
#==============================================================================#
{
    local l_output="$1"
    while read line
    do 
        log_warn "$line"
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

    mail -s "$HOSTNAME: $PROGRAM_NAME failed: $l_error_subject" "$EMAIL_LIST" < $LOG_FILE

    exit 1
}
#==============================================================================#
warn_email()
#==============================================================================#
{
    local l_error_subject=$1

    mail -s "$HOSTNAME: $PROGRAM_NAME failed: $l_error_subject" "$EMAIL_LIST" < $LOG_FILE
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
#
## This will strip out the grid home directory from the fully
## qualified path of the ohasd.bin returned in the ps-ef|grep ohasd.bin
#
    local has_process=$1

    echo $has_process|awk '{for(i=1;i<=NF;i++){if ($i ~ /ohasd.bin/){print $i}}}'| sed 's/\/bin\/ohasd\.bin.*$//'

    return
}
#==============================================================================#
start_database_with_sqlplus()
#==============================================================================#
{
    local l_database=$1

    ORAENV_ASK=NO
#
## Set oracle environment for database
#
    ORACLE_SID=$database
. oraenv >/dev/null<< EOF

EOF

    log_info ""
    log_info "Starting database $database"
    log_info "  ORACLE_SID: $ORACLE_SID"
    log_info "  ORACLE_HOME: $ORACLE_HOME"
    log_info "  ORACLE_BASE: $ORACLE_BASE"
    log_info "  LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
    log_info "  PATH: $PATH"
    log_info ""
#
## startup  instance 
#
    sqlplus -s /nolog >/dev/null << EOF
CONNECT / as sysdba
startup
EXIT
EOF

    return
}
#==============================================================================#
start_instances_with_sqlplus()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    local l_properties_file="${STATE_PATH}/${NOHAS_START_FILE}"

    log_info ""
    log_info "Checking if $l_properties_file properties file exist"
    if [ ! -e "$l_properties_file" ]; then
        log_error "$l_properties_file does not exist"
        log_error "Unable to determine previous shutdown state for databases"
        error_exit "Unable to determine previous shutdown state for databases"
    fi

    log_info "Reading properties $l_properties_file"
    while read -r line
    do
        IFS== read -r key database <<<"$line"
        case  "$key" in
            DATABASE)
                start_database_with_sqlplus $database
                ;;
            *)
                log_warn "Error parsing $l_properties_file"
                log_warn "   $key is unknown"
                ;;
        esac
    done <"$l_properties_file"

}
#==============================================================================#
sqlplus_shutdown()
#==============================================================================#
{
sqlplus -s /nolog >/dev/null << EOF
CONNECT / as sysdba
SHUTDOWN IMMEDIATE
EXIT
EOF
}
#==============================================================================#
shutdown_running_databases_with_sqlplus()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
#
## Loop through running database and find oracle home
#
    ORAENV_ASK=NO
    local l_num_count=0
    local l_yes_count=0
    for database in "${PMON_ARRAY[@]}"
    do
#
## Check to see if there is just one oratab entry for the database
#
        l_number_of_entries=$(awk "/^${database}:/" $ORATAB 2>/dev/null|wc -l)
        if [ $l_number_of_entries -ne 1 ]; then
            if [ $l_number_of_entries -eq 0 ]; then
                log_error "running instance: $database not present $ORATAB"
            else
                log_error "running instance: $database has $l_number_of_entries lines in oratab"
            fi
            log_error "Unable to stop running database"
            PMON_NO_ORATAB_ARRAY[l_num_count]=$database
            let l_num_count++
            continue
        fi
#
## save database name that we are stoping
#
        PMON_YES_ORATAB_ARRAY[l_yes_count]=$database
        let l_yes_count++
#
## Set oracle environment for database
#        
        ORACLE_SID=$database
. oraenv >/dev/null<< EOF

EOF

        log_info "ORACLE_SID: $ORACLE_SID"
        log_info "ORACLE_HOME: $ORACLE_HOME"
        log_info "ORACLE_BASE: $ORACLE_BASE"
        log_info "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
        log_info "PATH: $PATH"
        log_info ""
#
## run the sqlplus_shutdown function in the background
#
        sqlplus_shutdown &
        
    done
    ORAENV_ASK=YES
}
#==============================================================================#
shutdown_running_asm_with_sqlplus()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    ASM_PROCESS=`ps -ef|grep asm_pmon|grep -v grep`
    if [ $? -ne 0 ]; then
        log_info "No ASM instance found running"
        return 0
    fi

    log_info "$ASM_PROCESS"
    l_asm_inst=`echo $ASM_PROCESS | awk -F_ '{print $NF}'`
    log_info "asm_pmon = $l_asm_inst"
    log_info

    local l_properties_file="${STATE_PATH}/${ASM_START_FILE}"
    local l_properties_arch="${STATE_ARCH_PATH}/${ASM_START_FILE}_${RUN_TIMESTAMP}"

    log_info "Creating properties file $l_properties_file"
    log_info ""
    echo -n > $l_properties_file
    chmod 777 $l_properties_file

## Set oracle environment for database
#        
    ORACLE_SID=$l_asm_inst
. oraenv >/dev/null<< EOF

EOF

    log_info "ORACLE_SID: $ORACLE_SID"
    log_info "ORACLE_HOME: $ORACLE_HOME"
    log_info "ORACLE_BASE: $ORACLE_BASE"
    log_info "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
    log_info "PATH: $PATH"
    log_info ""
#
## shutdown ASM instance
#
#    sql_out=`sqlplus -s /nolog >/dev/null << EOF
    sql_out=`sqlplus /nolog<< EOF
WHENEVER SQLERROR EXIT 1
WHENEVER OSERROR EXIT 1
CONNECT / as sysdba
SHUTDOWN IMMEDIATE
EXIT
EOF`

    rtn=$?

#    if [ $rtn -ne 0 ]; then
#        log_error "Error shutting down ASM instance"
#        log_error_output "$sql_out"
#        return 1
#    fi

    local l_properties_file="${STATE_PATH}/${ASM_START_FILE}"
    local l_properties_arch="${STATE_ARCH_PATH}/${ASM_START_FILE}_${RUN_TIMESTAMP}"

    log_info "Creating properties file $l_properties_file"
    log_info ""
    echo -n > $l_properties_file
    chmod 777 $l_properties_file

    echo "$ORACLE_SID=$ORACLE_HOME" >> $l_properties_file

#
## Archive properties file
#
    cp $l_properties_file $l_properties_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive asm properties files"
        log_error "cp $l_properties_file $l_properties_arch failed"
    fi
    chmod 777 $l_properties_arch

    ORAENV_ASK=YES
}
#==============================================================================#
startup_asm_with_sqlplus()
#==============================================================================#
{
#
##  Start up asm instance with sqlplus
#
    log_header "${FUNCNAME[0]}()"
    local l_properties_file="${STATE_PATH}/${ASM_START_FILE}"
#
## Check the existance of the asm properties files created durning
## the stop.  If it does not exist, then show error and skip listener start
#
    log_info ""
    log_info "Checking if asm properties file exist"
    if [ ! -e "$l_properties_file" ]; then
        log_error "$l_properties_file does not exist"
        return
    fi

    log_info "Reading properties $l_properties_file"
    while read -r line
    do
        IFS== read -r asm_inst oracle_home <<<"$line"

        ORACLE_SID=$asm_inst

#        set_oracle_home $oracle_home
#
## Set oracle environment for database
#        
        ORACLE_SID=$asm_inst
. oraenv >/dev/null<< EOF

EOF

        log_info "Starting $asm_inst in $oracle_home"
        log_info
        log_info "ORACLE_SID: $ORACLE_SID"
        log_info "ORACLE_HOME: $ORACLE_HOME"
        log_info "ORACLE_BASE: $ORACLE_BASE"
        log_info "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
        log_info "PATH: $PATH"
        log_info ""
#
## starting ASM instance
#
        sql_out=`sqlplus /nolog<< EOF
WHENEVER SQLERROR EXIT 1
WHENEVER OSERROR EXIT 1
CONNECT / as sysdba
STARTUP
EXIT
EOF`

        rtn=$?

        if [ $rtn -ne 0 ]; then
            log_error "Error Starting ASM instance"
            log_error_output "$sql_out"
            return 1
        fi

        log_info "asm_inst started"

    done <"$l_properties_file"

    return
}
#==============================================================================#
instance_that_can_stop_exist()
#==============================================================================#
{
#
## loop though the array of captured running pmon process that have
## entiries in the oratab and return true if database passed in is found
## the script only stops running database found in the oratab
#
    l_in_database=$1
    rtn=1

    for l_database in "${PMON_YES_ORATAB_ARRAY[@]}"
    do
        if [ "$l_database" == "$l_in_database" ]; then
            rtn=0;
            break
        fi
    done

    return $rtn
    
}
#==============================================================================#
wait_for_sqlplus_stop_to_complete()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    local l_timeout=$MAX_DB_STOP_TIMEOUT
    log_info "MAX_DB_STOP_TIMEOUT: $l_timeout"

    log_info "Current Datetime = $(date)"
    let l_end_time=$(date +%s)+$l_timeout
    log_info "    End Datetime = $(date -d @${l_end_time})"
    l_first_time=true
#
## loop through running pmon process to wait for the database to shutdown
## if timeout is reached before all databases stop break out of the loop
#
    number_of_pmon_processes="$(ps -ef|grep ora_pmon_|grep -v grep|wc -l)"
    while [ "$number_of_pmon_processes" -gt 0 ]
    do
        number_of_pmon_processes="$(ps -ef|grep ora_pmon_|grep -v grep|wc -l)"
#
## if no pmon processes running, break out of the loop
## this means all shutdowns have completed
#
        if [ "$number_of_pmon_processes" -eq 0 ]; then
            break
        fi
#
## check pmon processes found for running instance with entires in the oratab
## if found add to the l_num_running_instances variable.
## all running instances without and oratab entry will be ignored
#
        local l_num_running_instances=0
        while read line
        do
            if [ ! -z "$line" ]; then
                local l_instance
                l_instance=`echo $line | awk -F_ '{print $NF}'`
                if ( instance_that_can_stop_exist $l_instance ); then
                    log_info "$l_instance is still runnning"
                    let l_num_running_instances++
                fi
            fi
        done <<< "$(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon')"
#
## break out of loop if no running instances were found
#
        if [ $l_num_running_instances -eq 0 ]; then
            break
        fi
#
## check to see if the MAX_DB_TIMEOUT has been reached
## Log warning and break out of loop
#            
        if [ $(date +%s) -gt $l_end_time ]; then
            log_warn ""
            log_warn "TIMEOUT reached while active pmon processes running"
            log_warn "The following database are running"
            log_warn ""
            print_list_of_pmon_processes
            break
        fi

        sleep $SLEEP_SECONDS
    done
}
#==============================================================================#
abort_still_running_shutdowns_with_sqlplus()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    local l_count=0
    while read line
    do
        if [ ! -z "$line" ]; then
            local l_instance
            l_instance=`echo $line | awk -F_ '{print $NF}'`
            if ( instance_that_can_stop_exist $l_instance ); then
                log_warn "$l_instance is still running.  Forcing database down"
                log_warn "Executing SQLPLUS startup force followed by shutdown immediate"
                log_info ""
#
## Set oracle environment for database
#        
                ORAENV_ASK=NO
                ORACLE_SID=$l_instance
. oraenv >/dev/null<< EOF

EOF
                ORAENV_ASK=YES

                log_info "ORACLE_SID: $ORACLE_SID"
                log_info "ORACLE_HOME: $ORACLE_HOME"
                log_info "ORACLE_BASE: $ORACLE_BASE"
                log_info "LD_LIBRARY_PATH: $LD_LIBRARY_PATH"
                log_info "PATH: $PATH"
                log_info ""
                let l_count++
#
## Forcing down database
#
                sqlplus -s /nolog >/dev/null << EOF
CONNECT / as sysdba
STARTUP FORCE
SHUTDOWN IMMEDIATE
EXIT
EOF
            fi
        fi
    done <<< "$(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon')"

    if [ $l_count -eq 0 ]; then
        log_info "Skipping Abort: All database stopped without issues"
    fi
}

#==============================================================================#
print_list_of_pmon_processes()
#==============================================================================#
{
    log_info_output "$(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon')"

    return
}

#==============================================================================#
stop_running_listeners()
#==============================================================================#
{
#
##   Poputlate LSNR_ARRAY with all the running instance
#
    log_header "${FUNCNAME[0]}()"

    local l_properties_file="${STATE_PATH}/${LISTENER_START_FILE}"
    local l_properties_arch="${STATE_ARCH_PATH}/${LISTENER_START_FILE}_${RUN_TIMESTAMP}"

    log_info "Running Listeners"
    log_info "$(ps -ef |grep tnslsnr|grep -v 'grep tnslsnr')"
    log_info ""

    log_info "Creating properties file $l_properties_file"
    log_info ""
    echo -n > $l_properties_file
    chmod 777 $l_properties_file

    local l_count=0
    while read line
    do
#if there are lines returned
        if [ ! -z "$line" ]; then
            local l_instance
            read -r executable listener_name <<<"$line"
            listener_home="$( echo "$executable" | sed -e 's/\/bin\/tnslsnr//' )"
            echo "$listener_name=$listener_home" >> $l_properties_file

            set_oracle_home $listener_home

            log_info "Stopping $listener_name in $listener_home"
            log_info "   Executing lsnrctl stop $listener_name"
#
## execute lsnrctl stop
## capture output in $output to be displayed in the log
#
            output="$(lsnrctl stop $listener_name)"

            if [ $? -eq 0 ]; then
                log_info_output "$output"
                log_info ""
            else
                log_error_output "$output"
                log_info ""
            fi
        fi
    done <<< "$(ps -ef |grep tnslsnr|grep -v 'grep tnslsnr'|awk '{print $(NF-2), $(NF-1)}')"
#
## Archive properties file
#
    cp $l_properties_file $l_properties_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive listener properties files"
        log_error "cp $l_properties_file $l_properties_arch failed"
    fi
    chmod 777 $l_properties_arch

}
#==============================================================================#
start_stopped_listeners()
#==============================================================================#
{
#
##  Start all listeners that were running when the last stop was executed
#
    log_header "${FUNCNAME[0]}() - PMON processes running"
    local l_properties_file="${STATE_PATH}/${LISTENER_START_FILE}"
#
## Check the existance of the listener properties files created durning
## the stop.  If it does not exist, then show error and skip listener start
#
    log_info ""
    log_info "Checking if $l_ohas_properties_file properties file exist"
    if [ ! -e "$l_properties_file" ]; then
        log_error "$l_properties_file does not exist"
        log_error "Unable to determine previous shutdown state for listeners"
        log_error "Listeners will need to be started manually after the run"
        return
    fi

    log_info "Reading properties $l_properties_file"
    while read -r line
    do
        IFS== read -r listener_name listener_home <<<"$line"
        set_oracle_home $listener_home

        log_info "Starting $listener_name in $listener_home"
        log_info "   Executing lsnrctl start $listener_name"
#
## execute lsnrctl start
## capture output in $output to be displayed in the log
#
        output="$(lsnrctl start $listener_name)"

        if [ $? -eq 0 ]; then
            log_info_output "$output"
            log_info ""
        else
            log_error_output "$output"
            log_info ""
        fi

    done <"$l_properties_file"
}
#==============================================================================#
get_running_pmon_instances()
#==============================================================================#
{
#
##   Poputlate PMON_ARRAY with all the running instance
#
    log_header "${FUNCNAME[0]}() - PMON processes running"
    local l_count=0

    while read line
    do
        #if there are lines returned
        if [ ! -z "$line" ]; then
            local l_instance
            l_instance=`echo $line | awk -F_ '{print $NF}'`
            if [ $? -eq 0 ]; then
                log_info "    $line"
                PMON_ARRAY[l_count]=$l_instance
                let l_count++
            fi
        fi
    done <<< "$(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon')"
}
#==============================================================================#
get_running_srvctl_databases()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    local l_count=0

    while read line
    do
        #if there are lines returned
        if [ ! -z "$line" ]; then
#
## Capture database name from crsctl stat res
#
            local l_database
            l_database=`echo $line | awk -F. '{print $2}'`
            if [ $? -eq 0 ]; then
                log_info "Checking database $l_database"
#
## Get the oracle home from the database
#
                local l_oracle_home="$(crsctl stat res ora.${l_database}.db -p|grep 'ORACLE_HOME='|awk -F= '{print $NF}')"
                log_info "  oracle_home for db: $l_oracle_home"
#
## Check to see if the database is running
#
                local l_output_1
                log_info "running: ${l_oracle_home}/bin/srvctl status database -d $l_database"
                l_output_1="$(${l_oracle_home}/bin/srvctl status database -d $l_database)"
                rtn=$?
                log_info "$l_output_1"
                if [ $rtn -eq 0 ]; then
                    local l_output_2
                    l_output_2="$(echo $l_output_1|grep 'is running')"
                    if [ $? -eq 0 ]; then
#
## Add to SRVCTL_DB_ARRAY the following 3 fields (database instance oracle_home
#
                        SRVCTL_DB_ARRAY[l_count]="$l_database $l_oracle_home"
                        let l_count++
                    fi
                fi
            fi
        fi
    done <<< "$(crsctl stat res -w "TYPE = ora.database.type"  -t|grep "^ora")"

    return
}

#==============================================================================#
get_running_srvctl_instances()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    local l_count=0

    while read line
    do
        #if there are lines returned
        if [ ! -z "$line" ]; then
#
## Capture database name from crsctl stat res
#
            local l_database
            l_database=`echo $line | awk -F. '{print $2}'`
            if [ $? -eq 0 ]; then
#
## Get the oracle home from the database
#
                local l_oracle_home="$(crsctl stat res ora.${l_database}.db -p|grep 'ORACLE_HOME='|awk -F= '{print $NF}')"
#
## Get the instance name if running from srvctl status instance
#
                l_output_1="$(srvctl status instance -d $l_database -n $NODENAME)"
                rtn=$?
                log_info "$l_output_1"
                if [ $rtn -eq 0 ]; then
                    l_output_2="$(echo $l_output_1|grep 'is running')"
                    if [ $? -eq 0 ]; then
                        local l_instance="$(echo $l_output_2| awk '{print $2}')"
                        log_info "    $l_database -> $l_instance"
#
## Add to SRVCTL_INST_ARRAY the following 3 fields (database instance oracle_home
#
                        SRVCTL_INST_ARRAY[l_count]="$l_database $l_instance $l_oracle_home"
                        let l_count++
                    fi
                fi
            fi
        fi
    done <<< "$(crsctl stat res -w "TYPE = ora.database.type"  -t|grep "^ora")"

}
#==============================================================================#
start_instances_with_srvctl()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() Starting instances"
#
## clear the start state file so it can be populated with the start commands
#
    local l_start_file=${STATE_PATH}/${SRVCTL_START_FILE}

    if [ ! -e $l_start_file ]; then
        log_error "$l_start_file is missing."
        log_error "Without knowing state of instances at last shutdown"
        log_error "will be onable to start instances"
        error_exit "$l_start_file is missing."
    fi

#
## run the stop commands for each instance running on the server
#

    while IFS='~' read l_oracle_home l_start_command
    do 
        set_oracle_home "$l_oracle_home"
        log_info "  ORACLE_HOME: $ORACLE_HOME"
        log_info "START COMMAND: $l_start_command"

        $l_start_command &

    done <<< "$(cat $l_start_file)"

    IFS=$ORIGINAL_IFS

    return
}
#==============================================================================#
stop_running_instances_with_srvctl()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() Stopping running instances"
#
## clear the start state file so it can be populated with the start commands
#
    local l_start_file=${STATE_PATH}/${SRVCTL_START_FILE}
    local l_start_arch_file=${STATE_ARCH_PATH}/${SRVCTL_START_FILE}_${RUN_TIMESTAMP}

    echo -n "" > $l_start_file
    chmod 777 $l_start_file

#
## run the stop commands for each instance running on the server
#
    for line in "${SRVCTL_INST_ARRAY[@]}"
    do
        echo $line | while read l_database l_instance l_oracle_home
        do
            set_oracle_home "$l_oracle_home"
            log_info ""
            log_info "   DATABASE: $l_database"
            log_info "   INSTANCE: $l_instance"
            log_info "ORACLE_HOME: $ORACLE_HOME"
#
## Build the stop and start commands
#
            local l_command_stop_line="${ORACLE_HOME}/bin/srvctl stop instance -d $l_database -n $NODENAME"
            local l_command_start_line="${ORACLE_HOME}/bin/srvctl start instance -d $l_database -n $NODENAME"
#
## Add start command to file that will be used to issue startup commands
#
            echo "$ORACLE_HOME~$l_command_start_line" >> $l_start_file 
            log_info "    COMMAND: $l_command_stop_line"
#
## Run generated stop command in the background
#
            $l_command_stop_line &

        done
    done
#
## make an archive of the start file
#
    cp $l_start_file $l_start_arch_file
    if [ $? -ne 0 ]; then
        log_error "Failed to archive start properties files"
        log_error "cp $l_start_file $l_start_arch_file failed"
    fi

    chmod 777 $l_start_arch_file

    return
}
#==============================================================================#
stop_running_databases_with_srvctl()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() Stopping running instances"
#
## clear the start state file so it can be populated with the start commands
#
    local l_start_file=${STATE_PATH}/${SRVCTL_START_FILE}
    local l_start_arch_file=${STATE_ARCH_PATH}/${SRVCTL_START_FILE}_${RUN_TIMESTAMP}

    echo -n "" > $l_start_file
    chmod 777 $l_start_file

#
## run the stop commands for each instance running on the server
#
    for line in "${SRVCTL_DB_ARRAY[@]}"
    do
        echo $line | while read l_database l_oracle_home
        do
            set_oracle_home "$l_oracle_home"
            log_info ""
            log_info "   DATABASE: $l_database"
            log_info "ORACLE_HOME: $ORACLE_HOME"
#
## Build the stop and start commands
#
            local l_command_stop_line="${ORACLE_HOME}/bin/srvctl stop database -d $l_database"
            local l_command_start_line="${ORACLE_HOME}/bin/srvctl start database -d $l_database"
#
## Add start command to file that will be used to issue startup commands
#
            echo "$ORACLE_HOME~$l_command_start_line" >> $l_start_file 
            log_info "    COMMAND: $l_command_stop_line"
#
## Run generated stop command in the background
#
            $l_command_stop_line &

        done
    done
#
## make an archive of the start file
#
    cp $l_start_file $l_start_arch_file
    if [ $? -ne 0 ]; then
        log_error "Failed to archive start properties files"
        log_error "cp $l_start_file $l_start_arch_file failed"
    fi
    chmod 777 $l_start_arch_file

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
get_grid_home_from_ohas_process()
#==============================================================================#
{
    HAS_PROCESS=`ps -ef|grep ohasd.bin|grep -v grep`

    log_header "${FUNCNAME[0]}()"

    let l_end_time=$(date +%s)+$FIND_HAS_TIMEOUT
    log_info "Waiting for Oracle High Availability process to start"
    while true
    do
        HAS_PROCESS=`ps -ef|grep ohasd.bin|grep -v grep`
        if [ $? -eq 0 ]; then
            log_info "found ohasd.bin process"
            log_info "  $HAS_PROCESS"
            GRID_ORACLE_HOME=$(get_high_availability_home "$HAS_PROCESS")
            log_info "GRID_ORACLE_HOME: $GRID_ORACLE_HOME"
            return
        fi

        if [ $(date +%s) -gt $l_end_time ]; then
            log_error ""
            log_error "ohasd.bin is not running not start with in $FIND_HAS_TIMEOUT seconds"
            log_error "    Exiting startup"
            error_exit "ohasd.bin is not running not start with in $FIND_HAS_TIMEOUT seconds"
        fi
        log_info "ohasd.bin is not running: Waiting for another $SLEEP_SECONDS seconds"
        sleep $SLEEP_SECONDS
    done
}
#==============================================================================#
set_type_of_running_service()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    RUNNING_SERVICE="UNKNOWN"
    HAS_PROCESS=`ps -ef|grep ohasd.bin|grep -v grep`
    if [ $? -eq 0 ]; then
        log_info "found ohasd.bin process"
        log_info "  $HAS_PROCESS"
        GRID_ORACLE_HOME=$(get_high_availability_home "$HAS_PROCESS")
        set_oracle_home_to_grid_home
        log_info "OHAS is running on server"
        log_header "${FUNCNAME[0]}()"
        local l_cluster_check
        l_cluster_check="$(crsctl check cluster 2> /dev/null)"
        if [ $? -eq 0 ]; then
            log_info ""
            log_info "Server is running on a rac cluster"
            log_output "$l_cluster_check"
            RUNNING_SERVICE="RAC"
            write_running_service_properties $RUNNING_SERVICE
        else
            local l_cluster_has
            l_cluster_has="$(crsctl check has)"
            if [ $? -eq 0 ]; then
                log_info ""
                log_info "Server is running standalone with OHAS service"
                log_output "$l_cluster_has"
                RUNNING_SERVICE="OHAS"
                write_running_service_properties $RUNNING_SERVICE
            fi
        fi
    else
        if [ $(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon' | wc -l) -gt 0 ]; then
            log_info "Server is running NOHAS service"
            RUNNING_SERVICE="NOHAS"
            write_running_service_properties $RUNNING_SERVICE
        fi
    fi

    log_info ""
    log_info "RUNNING_SERVICE: $RUNNING_SERVICE"

    return
}
#==============================================================================#
set_nodename_from_crsctl()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() - Hostname from crsctl"
    NODENAME=$(crsctl get nodename)
    if [ $? -ne 0 ]; then
        log_info "ERROR: try to get hostname by running crsctl get hostname"
        exit 2
    fi
    log_info "    NODENAME: $NODENAME"
}
#==============================================================================#
compare_stop_and_start_crsctl_status()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    
    local l_crsctl_stop="$STATE_PATH/$CRSCTL_STOP_STATUS_FILE"
    local l_crsctl_start="$STATE_PATH/$CRSCTL_START_STATUS_FILE"
    log_info ""
    log_info " Stop log: $l_crsctl_stop"
    log_info "Start log: $l_crsctl_start"
    log_info ""


    local l_diff_line_cnt=$(diff ${l_crsctl_stop}  ${l_crsctl_start}|wc -l)
    if [ "$l_diff_line_cnt" -gt 0 ]; then
        log_error "Difference found between stop and start crsctl stat res -t"
        log_error ""
        while read line
        do
            log_error "$line"
        done <<< "$(diff -y ${l_crsctl_stop} ${l_crsctl_start}|egrep "\|" -B2)"
        error_exit "Difference found between before and after in crsctl stat res -t"
    else
        log_info "crsctl stat res -t match between stop and start run"
    fi
}
#==============================================================================#
compare_stop_and_start_sqlplus_status()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    local l_nohas_stop="$STATE_PATH/$NOHAS_STOP_STATUS_FILE"
    local l_nohas_start="$STATE_PATH/$NOHAS_START_STATUS_FILE"
    log_info ""
    log_info " Stop log: $l_nohas_stop"
    log_info "Start log: $l_nohas_start"
    log_info ""


    local l_diff_line_cnt=$(diff ${l_nohas_stop}  ${l_nohas_start}|wc -l)
    if [ "$l_diff_line_cnt" -gt 0 ]; then
        log_error "Difference found between stop and start running processes"
        log_error ""
        while read line
        do
            log_error "$line"
        done <<< "$(diff -y ${l_nohas_stop} ${l_nohas_start}|egrep "\|" -B2)"
        error_exit "Difference found between before and after running processes"
    else
        log_info "Running processes match between stop and start run"
    fi
}
#==============================================================================#
capture_crsctl_status()
#==============================================================================#
{
    local l_crsctl_file="$STATE_PATH/$1"
    local l_crsctl_file_arch="$STATE_ARCH_PATH/${1}_${RUN_TIMESTAMP}"

    log_header "${FUNCNAME[0]}() - Write crsctl status to file"
#
## Capture database status
#
    crsctl stat res -t -w "TYPE = ora.database.type" >  $l_crsctl_file
    if [ $? -eq 0 ]; then
        log_info "crsctl stat res -t -w \"TYPE = ora.database.type\" $l_crsctl_file"
    else
        log_info "ERROR: unable to crsctl stat res -t -w \"TYPE = ora.database.type\""
        error_exit "ERROR: unable to crsctl stat res -t -w \"TYPE = ora.database.type\""
    fi
#
## Capture listener status
#
    crsctl stat res -t -w "TYPE = ora.listener.type" >> $l_crsctl_file
    if [ $? -eq 0 ]; then
        log_info "crsctl stat res -t -w \"TYPE = ora.listener.type\" $l_crsctl_file"
    else
        log_info "ERROR: unable to crsctl stat res -t -w \"TYPE = ora.listener.type\""
        error_exit "ERROR: unable to crsctl stat res -t -w \"TYPE = ora.listener.type\""
    fi

    cp $l_crsctl_file $l_crsctl_file_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive crsctl status"
        log_error "cp $l_crsctl_file $l_crsctl_file_arch failed"
    fi

    chmod 777 $l_crsctl_file
    chmod 777 $l_crsctl_file_arch
}
#==============================================================================#
capture_nohas_status()
#==============================================================================#
{
    local l_crsctl_file="$STATE_PATH/$1"
    local l_crsctl_file_arch="$STATE_ARCH_PATH/${1}_${RUN_TIMESTAMP}"

    log_header "${FUNCNAME[0]}() - Write crsctl status to file"

    ps -ef |grep tnslsnr|grep -v 'grep tnslsnr'|awk '{print $(NF-2), $(NF-1)}'| sort > $l_crsctl_file
    ps -ef |grep ora_pmon|grep -v 'grep ora_pmon'|awk '{print $(NF)}' | sort >> $l_crsctl_file

    cp $l_crsctl_file $l_crsctl_file_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive nohas status"
        log_error "cp $l_crsctl_file $l_crsctl_file_arch failed"
    fi
    chmod 777 $l_crsctl_file
    chmod 777 $l_crsctl_file_arch
}
#==============================================================================#
print_crsctl_database_resources()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() - crsctl stat res -w \"TYPE = ora.database.type\""
#
## Load crsctl status for databases in an array
#
    IFS=$'\n' CRS_DB_STATUS_LINES=($(crsctl stat res -w "TYPE = ora.database.type" -v))
#
## Set the minimum field size for data columns being captured
#
    NAME_LEN=4
    TARGET_LEN=6
    STATE_LEN=5
    LAST_SERVER_LEN=11
    STATE_DETAILS_LEN=13
#
## Get the max size for field columns
#
    for line in "${CRS_DB_STATUS_LINES[@]}"
    do
        IFS== read property value <<< $(echo $line)
        case $property in
            "NAME")
                NAME=$value
                NAME_LEN=$(update_length ${#value} $NAME_LEN)
                ;;
            "TARGET")
                TARGET=$value
                TARGET_LEN=$(update_length ${#value} $TARGET_LEN)
                ;;
            "STATE")
                STATE=$value
                STATE_LEN=$(update_length ${#value} $STATE_LEN)
                ;;
            "LAST_SERVER")
                LAST_SERVER=$value
                LAST_SERVER_LEN=$(update_length ${#value} $LAST_SERVER_LEN)
                ;;
            "STATE_DETAILS")
                STATE_DETAILS=$value
                STATE_DETAILS_LEN=$(update_length ${#value} $STATE_DETAILS_LEN)
                ;;
        esac
    done
#
## Print Heading for crsctl database status
#
    format="    %-${NAME_LEN}s  %-${TARGET_LEN}s  %-${STATE_LEN}s  %-${LAST_SERVER_LEN}s  %-${STATE_DETAILS_LEN}s\n"
    dash_line=$(printf "$format" $(head_line $NAME_LEN) \
                     $(head_line $TARGET_LEN) \
                     $(head_line $STATE_LEN) \
                     $(head_line $LAST_SERVER_LEN) \
                     $(head_line $STATE_DETAILS_LEN))
    log_info $(printf "$format" "NAME" "TARGET" "STATE" "LAST_SERVER" "STATE_DETAILS")
    log_info $(printf "$dash_line\n")
#
## Print details for all databases
#
    for line in "${CRS_DB_STATUS_LINES[@]}"
    do
        IFS== read property value <<< $(echo $line)
        case $property in
            "NAME")
                NAME=$value
                ;;
            "TARGET")
                TARGET=$value
                ;;
            "STATE")
                STATE=$value
                ;;
            "LAST_SERVER")
                LAST_SERVER=$value
                ;;
            "STATE_DETAILS")
                STATE_DETAILS=$value
                log_info $(printf "$format" $NAME $TARGET $STATE $LAST_SERVER $STATE_DETAILS)
                ;;
        esac
    done

    IFS=$ORIGINAL_IFS
}
#==============================================================================#
set_agent_home_from_oratab()
#==============================================================================#
{

    oratab_agent_line="$(ps -ef|grep "^agent" $ORATAB)"
    if [ $? -eq 0 ]; then
        echo "$oratab_agent_line"
        AGENT_ORACLE_HOME="$(echo $oratab_agent_line | awk -F: '{print $2}')"
        log_info "AGENT_HOME: $AGENT_ORACLE_HOME"
        return
    else
        log_header "${FUNCNAME[0]}()"
        log_warn "agent not found in oratab"
        log_warn "will not perform emctl blackout start/stop"
        log_warn ""
        warn_email "Unable to stop/start agent blackout. Agent not found in oratab"
        return 1
    fi
}
#==============================================================================#
start_blackout()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    if set_agent_home_from_oratab; then
        set_oracle_home $AGENT_ORACLE_HOME

        log_info "emctl start blackout UPDOWN_BLACKOUT -nodeLevel"
        output="$(emctl start blackout UPDOWN_BLACKOUT -nodeLevel)"
        if [ $? -eq 0 ]; then
            log_info_output "$output"
            log_info ""
        else
            log_warn_output "$output"
            log_warn ""
            warn_email "emctl start blackout UPDOWN_BLACKOUT failed"
        fi
    fi
    log_info "Comment out crontab with $BLACKOUT_COMMENT"
    crontab -l | sed s/^${BLACKOUT_COMMENT}// | sed s/^/${BLACKOUT_COMMENT}/ | crontab
}
#==============================================================================#
stop_blackout()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    if set_agent_home_from_oratab; then
        set_oracle_home $AGENT_ORACLE_HOME

        log_info "emctl stop blackout UPDOWN_BLACKOUT"
        output="$(emctl stop blackout UPDOWN_BLACKOUT)"
        if [ $? -eq 0 ]; then
            log_info_output "$output"
            log_info ""
        else
            log_warn_output "$output"
            log_warn ""
            warn_email "emctl stop blackout UPDOWN_BLACKOUT failed"
        fi
        log_info "emctl start agent"
        output="$(emctl start agent)"
        if [ $? -eq 0 ]; then
            log_info_output "$output"
            log_info ""
        else
            log_warn_output "$output"
            log_warn ""
            warn_email "emctl start agent failed"
        fi
    fi

    log_info "Uncomment out blackout in crontab, removing $BLACKOUT_COMMENT"
    crontab -l | sed s/^${BLACKOUT_COMMENT}// | crontab
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
update_length()
#==============================================================================#
{
    local old_val=$2
    local new_val=$1
    if (( new_val > old_val )); then
        echo $new_val
    else
        echo $old_val
    fi
    return
}
#==============================================================================#
wait_for_srvctl_commands_to_complete()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}() - wait for srvctl to $1 oracle instances"
#
## set timeout period based on stop or start
#
    local l_timeout=600
    case  "$1" in
        start)
            l_function="start"
            l_timeout=$MAX_DB_START_TIMEOUT
            ;;
        stop)
            l_function="stop"
            l_timeout=$MAX_DB_STOP_TIMEOUT
            ;;
        *)
            log_error "${FUNCNAME[0]}: requires one parameter (start/stop)"
            return 1
            ;;
    esac

    log_info "MAX_DB_TIMEOUT: $l_timeout seconds"
#
## Set the end_time based on current time + timeout seconds
#
    log_info "Current Datetime = $(date)"
    let l_end_time=$(date +%s)+$l_timeout
    log_info "    End Datetime = $(date -d @${l_end_time})"
    l_first_time=true
#
## loop until all srvctl stop/start have completed, or the timeout has been reached
#
    number_of_start_stops_running="$(ps -ef |grep "srvctl ${l_function} "|grep -v 'grep'|wc -l)"
    while [ "$number_of_start_stops_running" -gt 0 ]
    do
        number_of_start_stops_running="$(ps -ef |grep "srvctl ${l_function} "|grep -v 'grep'|wc -l)"
        if [ "$number_of_start_stops_running" -gt 0 ]; then
            sleep $SLEEP_SECONDS
            if $l_first_time; then
                log_info ""
                log_info "Waiting for all databases to $l_function"
                l_first_time=false
            fi
            log_info "    Sleeping for $SLEEP_SECONDS seconds."
        else
            log_info ""
#
## if we are running the stop process, and have no more running srvctl database stop commands
## and we find pmon process still out there, than log a warning
#
            if [ $l_function == "stop" ]; then
                if [ $(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon' | wc -l) -gt 0 ]; then
                    log_warn "All srvctl stop oracle homes completed"
                    log_warn ""
                    log_warn "The following databases are still up, and will be forced down with normal shutdown"
                    print_list_of_pmon_processes
                else
                    log_info "All srvctl stop databases completed"
                fi
            else
                if [ $(ps -ef |grep ora_pmon|grep -v 'grep ora_pmon' | wc -l) -gt 0 ]; then
                    log_info "All srvctl start databases completed"
                    log_info ""
                    log_info "The following databases have been started"
                    print_list_of_pmon_processes
                else
                    log_warn "All srvctl start database(s) completed"
                    log_warn "No databases have been started"
                fi
            fi
            break
        fi

#
## Adding sleep below, to give time for crsctl status to update
#
        sleep $SLEEP_SECONDS
            
        if [ $(date +%s) -gt $l_end_time ]; then
            log_warn ""
            log_warn "TIMEOUT reached while active srvctl ${l_function} home running"
            log_warn "$(ps -ef |grep "srvctl ${l_function} home"|grep -v 'grep')"
            log_warn ""
            log_info "The following database are running"
            print_list_of_pmon_processes
            break
        fi
    done
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
write_sqlplus_start_properties ()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"
    log_info "This is written on stop, so startup knows what databases to start"
    log_info

    local l_properties_file="${STATE_PATH}/${NOHAS_START_FILE}"
    local l_properties_arch="${STATE_ARCH_PATH}/${NOHAS_START_FILE}_${RUN_TIMESTAMP}"

    log_info "Creating properties file $l_properties_file"
    echo -n > $l_properties_file
    chmod 777 $l_properties_file

    for database in "${PMON_YES_ORATAB_ARRAY[@]}"
    do
        echo "DATABASE=${database}" >> $l_properties_file
    done

    cp $l_properties_file $l_properties_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive sqlplus properties files"
        log_error "cp $l_properties_file $l_properties_arch failed"
    fi
    chmod 777 $l_properties_arch

    return
}
#==============================================================================#
write_running_service_properties ()
#==============================================================================#
{
    local l_running_service=$1

    log_header "${FUNCNAME[0]}()"
    log_info "This is written on stop, so startup knows what type of services were running"
    log_info

    local l_properties_file="${STATE_PATH}/${RUNNING_SERVICE_FILE}"
    local l_properties_arch="${STATE_ARCH_PATH}/${RUNNING_SERVICE_FILE}_${RUN_TIMESTAMP}"

    log_info "Creating properties file $l_properties_file"
    echo -n > $l_properties_file
    chmod 777 $l_properties_file

    echo "SERVICE=${l_running_service}" > $l_properties_file

    cp $l_properties_file $l_properties_arch
    if [ $? -ne 0 ]; then
        log_error "Failed to archive running service properties files"
        log_error "cp $l_properties_file $l_properties_arch failed"
    fi
    chmod 777 $l_properties_arch

    return
}
#==============================================================================#
get_prev_running_service_type()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    local l_properties_file="${STATE_PATH}/${RUNNING_SERVICE_FILE}"

    RUNNING_SERVICE="UNKNOWN"

    log_info ""
    log_info "Checking if $l_properties_file properties file exist"
    if [ ! -e "$l_properties_file" ]; then
        log_error "$l_properties_file does not exist"
        log_error "Unable to determine previous running service state"
        error_exit "Unable to determine previous running service state"
    fi

    log_info "Reading properties $l_properties_file"
    while read -r line
    do
        IFS== read -r key running_type <<<"$line"
        case  "$key" in
            "SERVICE")
                RUNNING_SERVICE="$running_type"
                ;;
            *)
                log_warn "Error parsing $l_properties_file"
                log_warn "   $key is unknown"
                ;;
        esac
    done <"$l_properties_file"

    log_info "Previous running service was $running_type"

}
#==============================================================================#
find_oratab ()
#==============================================================================#
{
    log_header "${FUNCNAME[0]}()"

    if [ -e "/etc/oratab" ]; then
        ORATAB='/etc/oratab'
    elif [ -e "/var/opt/oracle/oratab" ]; then
        ORATAB='/var/opt/oracle/oratab'
    else
        log_error "Unable to find oratab file in /etc/oratab or /var/opt/oracle/oratab"
        error_exit "Unable to find oratab file"
    fi

    log_info "oratab found in $ORATAB"
}
#==============================================================================#
usage ()
#==============================================================================#
{
    echo "usage: $PROGRAM_NAME (start|stop|start_blackout|stop_blackout)"
    exit 1
}
#==============================================================================#
shutdown_all()
#==============================================================================#
{
#
## Find out if running RAC, OHAS or NO-OHAS
#
#    case $PLATFORM in
#      SunOS)
#        log_info "Running $PLATFORM"
#        RUNNING_SERVICE="NOHAS"
#      ;;
#      *)
#        set_type_of_running_service
#      ;;
#    esac

    set_type_of_running_service

    case  "$RUNNING_SERVICE" in
        RAC)
            get_running_pmon_instances
            set_nodename_from_crsctl
            capture_crsctl_status $CRSCTL_STOP_STATUS_FILE
            get_running_srvctl_instances
            stop_running_instances_with_srvctl 
            wait_for_srvctl_commands_to_complete stop
            ;;
        OHAS)
            get_running_pmon_instances
            print_crsctl_database_resources
            capture_crsctl_status $CRSCTL_STOP_STATUS_FILE
            get_running_srvctl_databases
            stop_running_databases_with_srvctl 
            wait_for_srvctl_commands_to_complete stop
            ;;
        NOHAS)
            capture_nohas_status $NOHAS_STOP_STATUS_FILE
            get_running_pmon_instances
            shutdown_running_databases_with_sqlplus
            wait_for_sqlplus_stop_to_complete
            abort_still_running_shutdowns_with_sqlplus
            shutdown_running_asm_with_sqlplus
            stop_running_listeners
            write_sqlplus_start_properties
            ;;
        *)
            log_error "Unable to determine the server setup"
            ;;
    esac
}
#==============================================================================#
startup_all()
#==============================================================================#
{
#
## Find out of the oracle high availability service is running
## If so, capture the directory of the grid home
#
#    case "$PLATFORM" in
#      SunOS)
#        RUNNING_SERVICE="NOHAS"
#      ;;
#      *)
#        get_grid_home_from_ohas_process
#        set_oracle_home_to_grid_home
#        wait_if_etc_initd_is_running_the_startup
#        set_type_of_running_service
#      ;;
#    esac

    get_prev_running_service_type

    case  "$RUNNING_SERVICE" in
        RAC)
            get_grid_home_from_ohas_process
            set_oracle_home_to_grid_home
            wait_if_etc_initd_is_running_the_startup

            wait_rac_cluster_to_come_online
            start_instances_with_srvctl 
            wait_for_srvctl_commands_to_complete start
            set_oracle_home_to_grid_home
            set_nodename_from_crsctl
            get_running_srvctl_instances
            capture_crsctl_status $CRSCTL_START_STATUS_FILE
            compare_stop_and_start_crsctl_status
            ;;
        OHAS)
            get_grid_home_from_ohas_process
            set_oracle_home_to_grid_home
            wait_if_etc_initd_is_running_the_startup

            start_instances_with_srvctl 
            wait_for_srvctl_commands_to_complete start
            set_oracle_home_to_grid_home
            print_crsctl_database_resources
            capture_crsctl_status $CRSCTL_START_STATUS_FILE
            compare_stop_and_start_crsctl_status
            ;;
        NOHAS)
            log_info "Running $PLATFORM"
            startup_asm_with_sqlplus            
            start_stopped_listeners
            start_instances_with_sqlplus 
            capture_nohas_status $NOHAS_START_STATUS_FILE
            compare_stop_and_start_sqlplus_status
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

find_oratab

case  "$1" in
    start)
        startup_all
        stop_blackout
        ;;
    stop)
        start_blackout
        shutdown_all
        ;;
    start_blackout)
        start_blackout
        ;;
    stop_blackout)
        stop_blackout
        ;;
    *)
        usage
        ;;
esac


