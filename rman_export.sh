#!/bin/ksh
#
# Script Name: ora_export.sh
# Script Purpose: Dynamically run an oracle export for a database on this machine
# Usage:  rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA> <SCHEMA NAME> <COMPRESS>
#
# Parmeters:  DB_ADMIN_DIR               - Admin Directory of the database
#             DBNAME                     - Name of the database to export
#             DEV/MOD/PROD               - Database level to determine which RMAN catalog to use
#             FULL/SCHEMA/PARFILE        - Used to tell the script whether it is doing a full, schema or parameter file export
#             SCHEMA NAME/PARFILE NAME   - Only required if doing a schema/parfile export, indicates what schema to export/parfile name
#             COMPRESS                   - Only required if wanting to compress the export file
#
# 06/16/2008  Nick Pranger   Created
# 07/22/2008  Nick Pranger   Changed the export filename to include the date and time of the export
#                             and to allow for comrpession of the export file
# 08/08/2008  Nick Pranger   Added a default export removal time of mtime +1 to the script to clean up old exports
#                             this time can be overridden by placing a DAYS_TO_KEEP valariable and value in the
#                             db environment file
# 08/20/2008  Nick Pranger   Made changes to use the .server_environ file instead of the .rman_environ file
#                               Added logic to log a message if the status table updates fail
# 08/27/2008 Nick Pranger   Made changes to use the dba_admin user to get information from the database instead of sys
# 02/09/2009 Nick Pranger   Made changes to open permissions on select files for Oracle Financials running under other users
# 02/10/2009 Nick Pranger   Version 8.0 release started on 2/10/2009
# 07/01/2009 Gennady Barenbaum Version 8.1 Added parameter file option.  File must reside in DB_ADMIN_DIR 
#
#set -x

#
# CD to the Users HOME Directory
#
cd `dirname $0`

#
# FUNCTIONS
#


#
# Check for a export flag indicating another export is already running
# Set the export flag if no other exports are running
#

fn_check_export_flag ()
{
  if [ ! -f ${DB_RMAN_DIR}/EXPORT_RUNNING_* ] ; then
    touch ${DB_RMAN_DIR}/EXPORT_RUNNING_${DBNAME}
    chown ${ORACLE_OWNER}:${ORACLE_GROUP} ${DB_RMAN_DIR}/EXPORT_RUNNING_${DBNAME}
  else
    echo " A database export is currently running against ${DBNAME}, please try again later."  | ${LOG_CMD_MAIN}

    export TS=`date '+%d-%b-%Y %H:%M'`
    export EXP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`

    export EXP_SUCC_FAIL='REDUNDANT'
    export EXP_FAIL_STAT='Export already running'
    fn_finish_status

    echo "******************************************************************"
    echo " " | ${LOG_CMD_MAIN}
    echo "\n\tFinish Time: ${TS}\n" | ${LOG_CMD_MAIN}
    echo "\n\tExiting Script: ${SCRIPT}\n" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    echo "******************************************************************"
    exit 0
  fi

}



#
# Do processing when the script fails
#

fn_script_failure_processing ()
{
  tail -50 ${LOG_CMD_MAIN}
}



#
# Write the final finish time status block out to the export log
#

fn_write_finish_time ()
{

  export TS=`date '+%d-%b-%Y %H:%M'`

  echo "******************************************************************"
  echo " " | ${LOG_CMD_MAIN}
  echo "\n\tFinish Time: ${TS}\n" | ${LOG_CMD_MAIN}
  echo "\n\tExiting Script: ${SCRIPT}\n" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}
  echo "******************************************************************"
}



#
# Clear the export flag after the export is complete
#

fn_clear_export_flag ()
{
  if [ -f ${DB_RMAN_DIR}/EXPORT_RUNNING_* ] ; then
    ${RM} -f ${DB_RMAN_DIR}/EXPORT_RUNNING_${DBNAME}
    echo " Export done for ${DBNAME}!"  | ${LOG_CMD_MAIN}
  fi
}



#
# Database controlfile backups
#

fn_backup_controlfile () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Backing up controlfile for database ${DBNAME}!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${RM} -f ${LOG_DIR}/backup_cf.control

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect ${DBADMINID}/${DBADMINPWD};
    set feedback off
    set pause off
    set trimspool on
    set heading off
    spool ${LOG_DIR}/dbcontrol.log
    alter database backup controlfile to '${LOG_DIR}/backup_cf.control';
    alter database backup controlfile to trace resetlogs;
    spool off
  exit;
EOT
  
  grep "ORA-" $LOG_DIR/dbcontrol.log
  
  if [ $? -eq 0 ]; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " Problem encountered when backing up database ${ORACLE_SID} controlfiles. Aborting!" | ${LOG_CMD_MAIN}
    echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN} 
    fn_clear_export_flag
    export EXP_SUCC_FAIL='FAILED'
    export EXP_FAIL_STAT='Unable to backup controlfiles properly'
    fn_finish_status
    fn_script_failure_processing
    exit 1
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Database ($ORACLE_SID) controlfile backups successful!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi
  ${RM} -f ${LOG_DIR}/dbcontrol.log
}



#
# Check the status of database. Proceed only when status = 'OPEN'
#

fn_check_dbstatus () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Checking database status!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect ${DBADMINID}/${DBADMINPWD};
    set feedback off
    set pause off
    set trimspool on
    set heading off
    spool ${LOG_DIR}/db_exp_status.log
    select status from v\$instance;
    spool off
  exit
EOT
  
  grep "OPEN" $LOG_DIR/db_exp_status.log
  
  if [ $? -ne 0 ]; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " Database ${ORACLE_SID} is not open do not perform export. Aborting!" | ${LOG_CMD_MAIN}
    echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN} 
    fn_clear_export_flag
    export EXP_SUCC_FAIL='FAILED'
    export EXP_FAIL_STAT='Database is not open - cannot perform export!'
    fn_finish_status
    fn_script_failure_processing
    exit 1
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Database ($ORACLE_SID) is open for export!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi
  ${RM} -f ${LOG_DIR}/db_exp_status.log
}



#
# Print out the variables set in run to primary log
#

fn_log_vars () 
{
  echo "SQLPLUS: ${SQLPLUS}" | ${LOG_CMD_MAIN}
  echo "ORAEXP: ${ORAEXP}" | ${LOG_CMD_MAIN}
  echo "ORACLE_SID: ${ORACLE_SID}" | ${LOG_CMD_MAIN}
  echo "ORACLE_HOME: ${ORACLE_HOME}" | ${LOG_CMD_MAIN}
  echo "ORACLE_USER: ${ORACLE_USER}" | ${LOG_CMD_MAIN}
  echo "SCRIPT: ${SCRIPT}" | ${LOG_CMD_MAIN}
  echo "RMAN_CATALOG: ${RMANID}" | ${LOG_CMD_MAIN}
  echo "RMAN_CATALOG_DATABASE: ${RMANSID}" | ${LOG_CMD_MAIN}
  echo "EXPORT_TYPE: ${EXP_TYPE}" | ${LOG_CMD_MAIN}
  echo "SCHEMA_NAME: ${SCHEMA_NAME}" | ${LOG_CMD_MAIN}
  echo "EXP_FILE: ${EXP_FILE}" | ${LOG_CMD_MAIN}
  echo "DAYS_TO_KEEP: ${DAYS_TO_KEEP}" | ${LOG_CMD_MAIN}
  echo "COMPRESS: ${COMPRESS}" | ${LOG_CMD_MAIN}
  echo "ZIP COMMAND: ${ZIPCMD}" | ${LOG_CMD_MAIN}
  echo "RM: ${RM}" | ${LOG_CMD_MAIN}
  echo "SLEEP: ${SLEEP}" | ${LOG_CMD_MAIN}
  echo "MKNOD: ${MKNOD}" | ${LOG_CMD_MAIN}
  echo "RAC_NORAC: ${RAC_NORAC}" | ${LOG_CMD_MAIN}
  echo "RAC_DBNAME: ${RAC_DBNAME}" | ${LOG_CMD_MAIN}
  echo "ORACLE_OWNER: ${ORACLE_OWNER}" | ${LOG_CMD_MAIN}
  echo "ORACLE_GROUP: ${ORACLE_GROUP}" | ${LOG_CMD_MAIN}
  echo "DB_REGION: ${DB_REGION}" | ${LOG_CMD_MAIN}
} 



#
# Check database for being a RAC database
#

fn_check_rac () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Determining if database is in a RAC database!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo 'set heading off' > ${SQL_FILE}
  echo 'set pagesize 0' >> ${SQL_FILE}
  echo 'set feedback off' >> ${SQL_FILE}
  echo 'set tab off' >> ${SQL_FILE}
  echo 'set trimout on' >> ${SQL_FILE}
  echo 'set linesize 100' >> ${SQL_FILE}
  echo 'select trim(parallel)' >> ${SQL_FILE}
  echo '  from v$instance;' >> ${SQL_FILE}

  RAC_NORAC=`cat ${SQL_FILE} | ${SQLPLUS} -s ${DBADMINID}/${DBADMINPWD}`

  export RAC_NORAC

  if [ ${RAC_NORAC} = 'NO' ] ; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Database is not a RAC database no further action needed." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    export RAC_DBNAME=${ORACLE_SID}
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Database is a RAC database, determine the DBNAME for shutdown." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}

    echo 'set heading off' > ${SQL_FILE}
    echo 'set pagesize 0' >> ${SQL_FILE}
    echo 'set feedback off' >> ${SQL_FILE}
    echo 'set tab off' >> ${SQL_FILE}
    echo 'set trimout on' >> ${SQL_FILE}
    echo 'set linesize 100' >> ${SQL_FILE}
    echo 'select lower(trim(name))' >> ${SQL_FILE}
    echo '  from v$database;' >> ${SQL_FILE}

    RAC_DBNAME=`cat ${SQL_FILE} | ${SQLPLUS} -s ${DBADMINID}/${DBADMINPWD}`

    export RAC_DBNAME

  fi
}



#
# Run the oracle command to export the database
#

fn_run_export()
{
  export TS=`date '+%d-%b-%Y %H:%M'`
  echo " " | ${LOG_CMD_MAIN}
  echo " Initiated EXPORT for a ${BKUP_TYPE} export of ${DBNAME} database at ${TS}!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  export EXP_OUT=${EXP_FILE}

  if [ ${COMPRESS} = 'YES' ]; then
    export EXP_OUT=${EXP_PIPE}
    ${RM} -f ${EXP_PIPE}
    ${MKNOD} ${EXP_PIPE} p
    ${ZIPCMD} < ${EXP_PIPE} > "${EXP_FILE}".gz &
    ${SLEEP} 1
  fi

  if [ ${EXP_TYPE} = 'FULL' ]; then
   ${ORAEXP} ${EXPID}/${EXPPWD} file=${EXP_OUT} log=${CURR_LOG} full=y direct=y compress=n statistics=none consistent=${EXP_CONSISTENT}

    VALUE_RET=$?
  elif [ ${EXP_TYPE} = 'SCHEMA' ]; then
    ${ORAEXP} ${EXPID}/${EXPPWD} file=${EXP_OUT} log=${CURR_LOG} owner=${SCHEMA_NAME} direct=y compress=n statistics=none consistent=${EXP_CONSISTENT}

    VALUE_RET=$?
  elif [ ${EXP_TYPE} = 'PARFILE' ]; then
    ${ORAEXP} ${EXPID}/${EXPPWD} file=${EXP_OUT} log=${CURR_LOG} parfile=${DBADMIN}/${PARFILE_NAME}

    VALUE_RET=$?
  fi

  cat ${CURR_LOG} | ${LOG_CMD_MAIN}

  if [ ${COMPRESS} = 'YES' ]; then
    ${RM} -f ${EXP_PIPE}
  fi

  export TS=`date '+%d-%b-%Y %H:%M'`
  export EXP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`

  if [ ${VALUE_RET} = 0 ] ; then
    if [ ${EXP_TYPE} = 'FULL' ]; then
      echo " " | ${LOG_CMD_MAIN}
      echo " Full export job SUCCESSFULL for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      export EXP_SUCC_FAIL='SUCCESSFUL'
      export EXP_FAIL_STAT='FULL Export successful'
      fn_finish_status
    else
      echo " " | ${LOG_CMD_MAIN}
      echo " Schema level export job SUCCESSFULL for ${SCHEMA_NAME} from ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      export EXP_SUCC_FAIL='SUCCESSFUL'
      export EXP_FAIL_STAT='SCHEMA level export successful'
      fn_finish_status
    fi
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Export job FAILED for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    fn_clear_export_flag 
    export EXP_SUCC_FAIL='FAILED'
    export EXP_FAIL_STAT='Export failed'
    fn_finish_status
    fn_script_failure_processing
    exit 1
  fi
}



#
# Remove old logs from database RMAN directory
#

fn_cleanup_logs () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Removing old EXPORT logs for ${DBNAME}!" | $LOG_CMD_MAIN
  echo " " | ${LOG_CMD_MAIN}
  find ${LOG_DIR} -name "*export*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  find ${LOG_DIR} -name "*report*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  chmod 660 ${LOG_DIR}/*.*
}



#
# Remove old export files from export location
#

fn_cleanup_exports () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Removing old EXPORT files for ${DBNAME}!" | $LOG_CMD_MAIN
  echo " " | ${LOG_CMD_MAIN}
  if [ ${DAYS_TO_KEEP} = 0 ]; then
    find ${BKDIR} -name "*.dmp*" -type f -print -exec ${RM} -f {} \;> /dev/null
  else
    find ${BKDIR} -name "*.dmp*" -type f -mtime +${DAYS_TO_KEEP} -print -exec ${RM} -f {} \;> /dev/null
  fi
}



#
# Insert the row for backup status into the status table at the start of the job
#

fn_start_status () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Inserting row into backup status table!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect ${STATID}/${STATPWD}@${STATSID}

    whenever sqlerror exit sql.sqlcode
    whenever oserror exit 9

    insert into backup_status_table
      (instance_name,
       dbname,
       server,
       db_type,
       rac_norac,
       backup_type,
       incremental_level,
       daily_monthly,
       disk_tape,
       start_time,
       backup_status,
       db_region)
    values
      ('${ORACLE_SID}',
       '${RAC_DBNAME}',
       '${NB_ORACLE_CLIENT}',
       '${PGM_LOC}',
       'UKNWN',
       'EXPORT',
       nvl('${INC_FULL}',0),
       'DAILY',
       'DISK',
       TO_DATE('${EXP_START_DATE}', 'dd-mon-yyyy HH24:MI'),
       'STILL RUNNING',
       '${DB_REGION}');
    commit;
  exit
EOT

  if [ $? -ne 0 ]; then
    echo " " | ${LOG_CMD_MAIN}
    echo " FAILED when inserting row into backup status table!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi

}



#
# Update the row for backup status to set the proper name and type for RAC/NORAC
#

fn_update_rac_status () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Updating row in backup status table to indicate RAC status!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect ${STATID}/${STATPWD}@${STATSID}

    whenever sqlerror exit sql.sqlcode
    whenever oserror exit 9

    update backup_status_table
       set rac_norac = decode('${RAC_NORAC}', 'YES', 'RAC',
                              'NO','NORAC',
                              'UKNWN'),
           dbname = '${RAC_DBNAME}'
     where instance_name = '${ORACLE_SID}'
       and server = '${NB_ORACLE_CLIENT}'
       and db_type = '${PGM_LOC}'
       and rac_norac = 'UKNWN'
       and db_region = '${DB_REGION}';
    commit;
  exit
EOT

  if [ $? -ne 0 ]; then
    echo " " | ${LOG_CMD_MAIN}
    echo " FAILED when updating row in backup status table to indicate RAC status!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi

}



#
# Update the row for backup status at the end of the export job
#

fn_finish_status () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Updating row in backup status table!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect ${STATID}/${STATPWD}@${STATSID}

    whenever sqlerror exit sql.sqlcode
    whenever oserror exit 9

    update backup_status_table
       set finish_time = TO_DATE('${EXP_FINISH_DATE}', 'dd-mon-yyyy HH24:MI'),
           backup_status = '${EXP_SUCC_FAIL}',
           backup_status_message = '${EXP_FAIL_STAT}'
     where instance_name = '${ORACLE_SID}'
       and dbname = '${RAC_DBNAME}'
       and server = '${NB_ORACLE_CLIENT}'
       and db_type = '${PGM_LOC}'
       and rac_norac = decode('${RAC_NORAC}', 'YES', 'RAC',
                              'NO','NORAC',
                              'UKNWN')
       and backup_type = 'EXPORT'
       and incremental_level = nvl('${INC_FULL}', 0)
       and daily_monthly = 'DAILY'
       and disk_tape = 'DISK'
       and start_time = TO_DATE('${EXP_START_DATE}', 'dd-mon-yyyy HH24:MI')
       and db_region = '${DB_REGION}';
    commit;
  exit
EOT

  if [ $? -ne 0 ]; then
    echo " " | ${LOG_CMD_MAIN}
    echo " FAILED when updating row in backup status table!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi

}



#
#  MAIN CODE
#



#
# Check input variables
#

  if [ -z $1 ]; then 
    echo "Database admin directory was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
    echo "Aborting!"
    exit 1
  fi
  
  if [ -z $2 ]; then 
    echo "DB Name was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
    echo "Aborting!"
    exit 1
  fi
  
  if [ -z $3 ]; then 
    echo "DB Level (DEV/MOD/PROD) was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
    echo "Aborting!"
    exit 1
  else
    case $3 in
       DEV) ;;
       MOD) ;;
      PROD) ;;
         *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
            echo "Correct format for calling is : "
            echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
            echo "Aborting!"
            exit 1;;
    esac
  fi
  
  if [ -z $4 ]; then 
    echo "Export type (FULL/SCHEMA/PARFILE) was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
    echo "Aborting!"
    exit 1
  else
    case $4 in
        FULL) INC_FULL=0
              SCHEMA_NAME=full
              if [ -z $5 ]; then
                export COMPRESS=NO
              else
                export COMPRESS=YES
              fi;;
      SCHEMA) if [ -z $5 ]; then
                echo "Schema name (SCHEMA NAME) was not passed correctly."
                echo "Correct format for calling is : "
                echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
                echo "Aborting!"
                exit 1
              else
                typeset -u SCHEMA_NAME
                export SCHEMA_NAME=$5
                export INC_FULL=1
                if [ -z $6 ]; then
                  export COMPRESS=NO
                else
                  export COMPRESS=YES
                fi
              fi;;
     PARFILE) if [ -z $5 ]; then
                echo "Parameter file name (PARFILE NAME) was not passed correctly."
                echo "Correct format for calling is : "
                echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME>."
                echo "Aborting!"
                exit 1
              else
                export PARFILE_NAME=$5
                if [ ! -f ${1}/${PARFILE_NAME} ]; then
                  echo "Parameter file name ${PARFILE_NAME} could not be found in DB_ADMIN_DIR(${1})."
                  echo "Aborting!"
                  exit 1
                fi 
                export INC_FULL=1
                if [ -z $6 ]; then
                  export COMPRESS=NO
                else
                  export COMPRESS=YES
                fi
              fi;;
           *) echo "Export type (FULL/SCHEMA/PARFILE) was not passed correctly."
              echo "Correct format for calling is : "
              echo "rman_export.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <FULL/SCHEMA/PARFILE> <SCHEMA NAME/PARFILE NAME> <COMPRESS>."
              echo "Aborting!"
              exit 1;;
    esac
  fi



#
# Set up Script Variables and Environment
#

  export DBADMIN=$1
  export DBNAME=$2
  export PGM_LOC=$3
  export EXP_TYPE=$4
  export ORACLE_OWNER=oracle
  export ORACLE_GROUP=dba
  export COMPRESS_BKUP=N
  export DB_REGION=NA

  export DAYS_TO_KEEP=1
  export EXP_CONSISTENT=y

#
# The below 3 environment sourcing lines are done in this manner on purpose
#   the .{DBNAME}_env file is sourced to get the proper ORACLE_HOME information for the database
#   the .server_environ file is then sourced to get the default values for variables and general setups
#   the .{DBNAME}_env file is then sourced a second time to do overrides of the defaults if needed
#

  . ${DBADMIN}/.${DBNAME}_env
  . `dirname $0`/../.server_environ
  . ${DBADMIN}/.${DBNAME}_env

  export RAC_DBNAME=${ORACLE_SID}
  export RAC_NORAC=UKNWN

  DB_RMAN_DIR=${DBADMIN}/rman
  if [ ! -d ${DB_RMAN_DIR} ]; then
     mkdir -p ${DB_RMAN_DIR}
     if [ $? -ne 0 ]; then
        echo " Error creating log directory ${DB_RMAN_DIR}. Aborting!/n"
        exit 1
     fi
  fi
  LOG_DIR=${DB_RMAN_DIR}

  if [ ${COMPRESS} = 'NO' ]; then
    if [ ${COMPRESS_BKUP} = 'Y' ]; then
      export COMPRESS=YES
    fi
  fi

#
# The following code sets up one master output file that everything goes to
#

export EXP_FILE_DATE=`date '+%b.%d.%y-%H.%M'`

case ${EXP_TYPE} in
    FULL) OUTF=${LOG_DIR}/call_export_full.sh.out
          SCRIPT_NAME=export_full
          SCRIPT=call_export_full.sh
          export EXP_FILE=${BKDIR}/exp_${DBNAME}_${EXP_FILE_DATE}_full.dmp
          export EXP_PIPE=${BKDIR}/exp_pipe_${DBNAME}_${EXP_FILE_DATE}_full;;
  SCHEMA) OUTF=${LOG_DIR}/call_export_${SCHEMA_NAME}.sh.out
          SCRIPT_NAME=export_${SCHEMA_NAME}
          SCRIPT=call_export_${SCHEMA_NAME}.sh
          export EXP_FILE=${BKDIR}/exp_${DBNAME}_${EXP_FILE_DATE}_${SCHEMA_NAME}.dmp
          export EXP_PIPE=${BKDIR}/exp_pipe_${DBNAME}_${EXP_FILE_DATE}_${SCHEMA_NAME};;
 PARFILE) OUTF=${LOG_DIR}/call_export_parfile.sh.out
          SCRIPT_NAME=export_parfile
          SCRIPT=call_export_parfile.sh
          export EXP_FILE=${BKDIR}/exp_${DBNAME}_${EXP_FILE_DATE}_parfile.dmp
          export EXP_PIPE=${BKDIR}/exp_pipe_${DBNAME}_${EXP_FILE_DATE}_parfile;;
esac

{ 
  export TS=`date '+%d-%b-%Y %H:%M'`
  export EXP_START_DATE=`date '+%d-%b-%Y %H:%M'`

  MAIN_LOG=${LOG_DIR}/${SCRIPT_NAME}_${DBNAME}_`date +%Y%m%d%H%M`.log
  CURR_LOG=${LOG_DIR}/${SCRIPT_NAME}_${DBNAME}.log
  LOG_CMD_MAIN="tee -a ${MAIN_LOG}"

  echo "`date` ----------------Beginning of Script------------"

  echo "******************************************************************"
  echo "\n\tScript Name: ${SCRIPT}\n" | ${LOG_CMD_MAIN}
  echo "\n\tStart Time: ${TS}\n" | ${LOG_CMD_MAIN}
  echo "\n\tMain Log: ${MAIN_LOG}\n" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}
  echo "******************************************************************"

  export TS=`date '+%d-%b-%Y %H:%M'`
  SQLPLUS="$ORACLE_HOME/bin/sqlplus"
  ORACLE_USER=`whoami`
  
  SQL_FILE=${DB_RMAN_DIR}/rman_sqlfile_${DBNAME}.sql

  if [ ! -d ${BKDIR} ]; then
    echo "Export requested, but the export directory of ${BKDIR} does not exist. Aborting!"
    exit 1
  fi

  ${RM} -f ${CURR_LOG}
  touch ${CURR_LOG}
  cat /dev/null > ${CURR_LOG}
  
#
#  Run Script
#

  fn_start_status

  export TS=`date '+%d-%b-%Y %H:%M'`

  echo "Starting ${EXP_TYPE} export of ${DBNAME} at ${TS}." | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  fn_check_dbstatus

  fn_check_export_flag

  fn_check_rac

  fn_update_rac_status

  fn_log_vars

  fn_cleanup_exports

  fn_run_export

  fn_backup_controlfile

  fn_cleanup_logs

  fn_clear_export_flag

  fn_write_finish_time

} > ${OUTF}
exit 0


