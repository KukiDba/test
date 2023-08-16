#!/bin/ksh
#
# Script Name: rman_backup.sh
# Script Purpose: Dynamically run an rman database backup for a database on this machine
# Usage:  rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY Optional> <DISK/TAPE Optional>
#
# Parmeters:  DB_ADMIN_DIR              - Admin Directory of the database
#             DBNAME                    - Name of the database to backup
#             DEV/MOD/PROD              - Database level to determine which RMAN catalog to use
#             HOT/COLD/ARCH             - Used to tell the script whether it is doing a hot or cold database backup
#                                         or only an archivelog backup
#             Incremental Level         - Only required if doing a hot database backup, indicates what level
#                                         of incremental backup to do (Level 0 for a full)
#             DAILY/WEEKLY/MONTHLY      - Optional parameter to manually force run a daily or monthly backup
#                                         if omitted the default type of backup for that day will run
#             DISK/TAPE                 - Optional parameter to push backups to the disk location of BKDIR in db environment file
#                                         if omitted or incorrectly entered the default value for this is TAPE
#
# 6/12/2007  Nick Pranger   Created
# 7/20/2007  S Mohammed     Added ARCH backup override settings (to be set in .<db>_env file:
#                               RMAN_ALWAYS_INCLUDE_ARCH - Setting to always do ARCH backup after any HOT backup.Set to 'Y' to enable
# 7/23/2007  S Mohammed     Commented out "tag" line from ARCH section of fn_gen_cmd() - not compatible with 816 RMAN
# 10/17/2007 Nick Pranger   Changed the ADMIN directory parameter to be the database admin directory instead of the machine admin directory
#                           Added the functionality to choose to back up to disk or tape instead of tape only
# 10/30/2007 Nick Pranger   Made changes to reflect proper times when outputting them to the log files.
# 01/30/2008 Nick Pranger   Made changes to write backup status information to the separate schema in the rman catalogs
# 04/08/2008 Nick Pranger   Made changes to stop archivelog backups from starting when a normal backup is already running
#                               This appears to be necessary to avoid failures related to controlfile enque contention
# 04/14/2008 Nick Pranger   Made changes to fix reporting problems with running of archivelog backups following a hot backup automatically
# 08/08/2008 Nick Pranger   Made changes to allow for doing cold backups on RAC databases
# 08/20/2008 Nick Pranger   Made changes to use the .server_environ file instead of the .rman_environ file
#                               Added logic to log a message if the status table updates fail
# 08/27/2008 Nick Pranger   Made changes to use the dba_admin user to get information from the database instead of sys
# 02/09/2009 Nick Pranger   Made changes to open permissions on select files for Oracle Financials running under other users
# 02/10/2009 Nick Pranger   Version 8.0 release started on 2/10/2009
# 11/19/2009 Nick Pranger   Version 8.2 release started on 11/19/2009 This release changes incremental backups to run as cumulative
#                               incrementals rather than normal incrementals
# 04/30/2010 Nick Pranger   Version 8.3 release started on 04/30/2010 This release fixes a problem with the automatic ARCH backup after
#                               a hot backup if the backup is run to disk where the arch backup did not go to the proper place.
# 30/07/2012 Tony.J.Thomas  Version 9.0 Added functionality to perform weekly backups.
#                                       Added functionality to allow for dynamically changing the files_per_set on backups and archivelog backups
#                                       Made modifications in rman command generation to handle multiple channels cleaner by backing up control files
#                                            after all datafiles have been completed.
# 20/12/2012 Tony.J.Thomas  Version 9.1  Fixed the issue  in script  where it  was not  able to set weekly netbackup policy
#
#




#
# CD to the Users HOME Directory
#
cd `dirname $0`

#
# FUNCTIONS
#



#
# Check for a backup flag indicating another backup is already running
# Set the backup flag if no other backups are running
#

fn_check_backup_flag ()
{
  if [ ${BKUP_TYPE} = 'ARCH' ] ; then
    if [ ! -f ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_* ] ; then
      if [ ! -f ${DB_RMAN_DIR}/BACKUP_RUNNING_BKUP_* ] ; then
        touch ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_${DBNAME}
        chown ${ORACLE_OWNER}:${ORACLE_GROUP} ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_${DBNAME}
      else
        echo " A database backup is currently running against ${DBNAME}, please try again later."  | ${LOG_CMD_MAIN}

        export TS=`date '+%d-%b-%Y %H:%M'`
        export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`

        export BKUP_SUCC_FAIL='REDUNDANT'
        export BKUP_FAIL_STAT='Backup already running'
        fn_finish_status

        echo "******************************************************************"
        echo " " | ${LOG_CMD_MAIN}
        echo "\n\tFinish Time: ${TS}\n" | ${LOG_CMD_MAIN}
        echo "\n\tExiting Script: ${SCRIPT}\n" | ${LOG_CMD_MAIN}
        echo " " | ${LOG_CMD_MAIN}
        echo "******************************************************************"
        exit 0
      fi

      touch ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_${DBNAME}
      chown ${ORACLE_OWNER}:${ORACLE_GROUP} ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_${DBNAME}
    else
      echo " An archivelog backup is currently running against ${DBNAME}, please try again later."  | ${LOG_CMD_MAIN}

      export TS=`date '+%d-%b-%Y %H:%M'`
      export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`

      export BKUP_SUCC_FAIL='REDUNDANT'
      export BKUP_FAIL_STAT='Archivelog Backup already running'
      fn_finish_status

      echo "******************************************************************"
      echo " " | ${LOG_CMD_MAIN}
      echo "\n\tFinish Time: ${TS}\n" | ${LOG_CMD_MAIN}
      echo "\n\tExiting Script: ${SCRIPT}\n" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      echo "******************************************************************"
      exit 0
    fi
  else
    if [ ! -f ${DB_RMAN_DIR}/BACKUP_RUNNING_BKUP_* ] ; then
      touch ${DB_RMAN_DIR}/BACKUP_RUNNING_BKUP_${DBNAME}
      chown ${ORACLE_OWNER}:${ORACLE_GROUP} ${DB_RMAN_DIR}/BACKUP_RUNNING_BKUP_${DBNAME}
    else
      echo " A backup is currently running against ${DBNAME}, please try again later."  | ${LOG_CMD_MAIN}

      export TS=`date '+%d-%b-%Y %H:%M'`
      export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`

      export BKUP_SUCC_FAIL='REDUNDANT'
      export BKUP_FAIL_STAT='Backup already running'
      fn_finish_status

      echo "******************************************************************"
      echo " " | ${LOG_CMD_MAIN}
      echo "\n\tFinish Time: ${TS}\n" | ${LOG_CMD_MAIN}
      echo "\n\tExiting Script: ${SCRIPT}\n" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      echo "******************************************************************"
      exit 0
    fi
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
# Write the final finish time status block out to the backup log
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
# Clear the backup flag after the backup is complete
#

fn_clear_backup_flag ()
{
  if [ ${BKUP_TYPE} = 'ARCH' ] ; then
    if [ -f ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_* ] ; then
      ${RM} -f ${DB_RMAN_DIR}/BACKUP_RUNNING_ARCH_${DBNAME}
      echo " Archive backup done for ${DBNAME}!"  | ${LOG_CMD_MAIN}
    fi
  else
    if [ -f ${DB_RMAN_DIR}/BACKUP_RUNNING_BKUP_* ] ; then
      ${RM} -f ${DB_RMAN_DIR}/BACKUP_RUNNING_BKUP_${DBNAME}
      echo " Database backup done for ${DBNAME}!"  | ${LOG_CMD_MAIN}
    fi
  fi

  if [ ${BKUP_SUCC_FAIL} = 'FAILED' ]; then
    if [ ${BKUP_TYPE} = 'COLD' ]; then
      fn_force_open_db
    fi
  fi
}



#
# Restart database in mount only for COLD backup
#

fn_mount_db ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Bouncing and mounting database for COLD backup!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  if [ ${RAC_NORAC} = 'YES' ] ; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Stopping the RAC database for COLD backup!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}

    ${SRVCTL} stop database -d ${RAC_DBNAME}
    VALUE_RET=$?

    if [ ${VALUE_RET} = 0 ]; then
      echo " " | ${LOG_CMD_MAIN}
      echo " RAC Database ${RAC_DBNAME} stopped SUCCESSFULLY!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
    else
      export TS=`date '+%d-%b-%Y %H:%M'`
      export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`
      echo " " | ${LOG_CMD_MAIN}
      echo " RAC Database ${RAC_DBNAME} did not stop properly!" | ${LOG_CMD_MAIN}
      echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      export BKUP_SUCC_FAIL='FAILED'
      export BKUP_FAIL_STAT='RAC Database Stop Failed for COLD Backup'
      fn_finish_status
      fn_clear_backup_flag
      fn_script_failure_processing
      exit 1
    fi
  fi

  if [ ${RAC_NORAC} = 'YES' ] ; then
    ${SQLPLUS} /nolog << EOT > /dev/null
      connect / as sysdba;
      set feedback off
      set pause off
      set trimspool on
      set heading off
      spool ${LOG_DIR}/dbmount.log
      startup mount;
      spool off
    exit;
EOT
  else
    ${SQLPLUS} /nolog << EOT > /dev/null
      connect / as sysdba;
      set feedback off
      set pause off
      set trimspool on
      set heading off
      spool ${LOG_DIR}/dbmount.log
      shutdown immediate;
      startup mount;
      spool off
    exit;
EOT
  fi

  grep "ORA-" $LOG_DIR/dbmount.log

  if [ $? -eq 0 ]; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " Problem encountered when mounting database ${ORACLE_SID} for cold backup. Aborting!" | ${LOG_CMD_MAIN}
    echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    fn_clear_backup_flag
    export BKUP_SUCC_FAIL='FAILED'
    export BKUP_FAIL_STAT='Unable to mount database for cold backup'
    fn_finish_status
    fn_clear_backup_flag
    fn_script_failure_processing
    exit 1
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Database ($ORACLE_SID) is mounted and ready for cold backup!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi
  ${RM} -f ${LOG_DIR}/dbmount.log
}



#
# Open database after a cold backup has been completed
#

fn_open_db ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Opening database after COLD backup!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect / as sysdba;
    set feedback off
    set pause off
    set trimspool on
    set heading off
    spool ${LOG_DIR}/dbopen.log
    alter database open;
    spool off
  exit;
EOT

  grep "ORA-" $LOG_DIR/dbopen.log

  if [ $? -eq 0 ]; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " Problem encountered when opening database ${ORACLE_SID} after cold backup. Aborting!" | ${LOG_CMD_MAIN}
    echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    export BKUP_SUCC_FAIL='FAILED'
    export BKUP_FAIL_STAT='Unable to open database after cold backup'
    fn_finish_status
    fn_clear_backup_flag
    fn_script_failure_processing
    exit 1
  else
    if [ ${RAC_NORAC} = 'YES' ] ; then
      echo " " | ${LOG_CMD_MAIN}
      echo " Shutting down the instance and starting the RAC database after COLD backup!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}

      ${SQLPLUS} /nolog << EOT > /dev/null
        connect / as sysdba;
        set feedback off
        set pause off
        set trimspool on
        set heading off
        spool ${LOG_DIR}/dbshut.log
        shutdown immediate;
        spool off
      exit;
EOT

      grep "ORA-" $LOG_DIR/dbshut.log

      if [ $? -eq 0 ]; then
        export TS=`date '+%d-%b-%Y %H:%M'`
        export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`
        echo " " | ${LOG_CMD_MAIN}
        echo " Problem encountered when shutting down instance ${ORACLE_SID} after cold backup for RAC ${RAC_DBNAME}. Aborting!" | ${LOG_CMD_MAIN}
        echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
        echo " " | ${LOG_CMD_MAIN}
        export BKUP_SUCC_FAIL='FAILED'
        export BKUP_FAIL_STAT='Unable to shutdown database after cold backup'
        fn_finish_status
        fn_clear_backup_flag
        fn_script_failure_processing
        exit 1
      else

        ${SRVCTL} start database -d ${RAC_DBNAME}
        VALUE_RET=$?

        if [ ${VALUE_RET} = 0 ]; then
          echo " " | ${LOG_CMD_MAIN}
          echo " RAC Database ${RAC_DBNAME} started SUCCESSFULLY!" | ${LOG_CMD_MAIN}
          echo " " | ${LOG_CMD_MAIN}
          echo " Database ($ORACLE_SID) is open and ready for use after cold backup!" | ${LOG_CMD_MAIN}
          echo " " | ${LOG_CMD_MAIN}
        else
          export TS=`date '+%d-%b-%Y %H:%M'`
          export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`
          echo " " | ${LOG_CMD_MAIN}
          echo " RAC Database ${RAC_DBNAME} did not start properly!" | ${LOG_CMD_MAIN}
          echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
          echo " " | ${LOG_CMD_MAIN}
          export BKUP_SUCC_FAIL='FAILED'
          export BKUP_FAIL_STAT='RAC Database Start Failed for COLD Backup'
          fn_finish_status
          fn_clear_backup_flag
          fn_script_failure_processing
          exit 1
        fi
      fi
    else
      echo " " | ${LOG_CMD_MAIN}
      echo " Database ($ORACLE_SID) is open and ready for use after cold backup!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
    fi
  fi
  ${RM} -f ${LOG_DIR}/dbopen.log
  ${RM} -f ${LOG_DIR}/dbshut.log
}



#
# Try to force Open database after a cold backup has been failed
#

fn_force_open_db ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Opening database after COLD backup!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${SQLPLUS} /nolog << EOT > /dev/null
    connect / as sysdba;
    set feedback off
    set pause off
    set trimspool on
    set heading off
    spool ${LOG_DIR}/dbopen.log
    alter database open;
    spool off
  exit;
EOT

  if [ ${RAC_NORAC} = 'YES' ] ; then
    ${SRVCTL} start database -d ${RAC_DBNAME}
  fi

  ${RM} -f ${LOG_DIR}/dbopen.log
  ${RM} -f ${LOG_DIR}/dbshut.log
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
    fn_clear_backup_flag
    export BKUP_SUCC_FAIL='FAILED'
    export BKUP_FAIL_STAT='Unable to backup controlfiles properly'
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
    spool ${LOG_DIR}/dbstatus.log
    select status from v\$instance;
    spool off
  exit
EOT

  grep "OPEN" $LOG_DIR/dbstatus.log

  if [ $? -ne 0 ]; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " Database ${ORACLE_SID} is not open do not perform backup. Aborting!" | ${LOG_CMD_MAIN}
    echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    export BKUP_SUCC_FAIL='FAILED'
    fn_clear_backup_flag
    export BKUP_FAIL_STAT='Database is not open cannot perform backup'
    fn_finish_status
    fn_script_failure_processing
    exit 1
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Database ($ORACLE_SID) is open for backup!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi
#  ${RM} -f ${LOG_DIR}/dbstatus.log
}



#
# Generate the RMAN command file to perform the backup based on input parameters
#

fn_gen_cmd()
{


  echo " " | ${LOG_CMD_MAIN}
  echo "Create RMAN Command file for backing up database or archivelogs." | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "connect target;" > ${CMDFILE}
  echo "connect catalog ${RMANID}/${RMANPWD}@${RMANSID};" >> ${CMDFILE}
  echo "run {" >> ${CMDFILE}

  THREADKOUNT=0
  while [ ${THREADKOUNT} -lt ${NB_CHANNELS} ]
  do
    THREADKOUNT=`expr ${THREADKOUNT} + 1`

    case ${DISK_TAPE} in
      DISK) echo "allocate channel c$THREADKOUNT type disk format '${NB_FILE_FMT}';" >> ${CMDFILE};;
         *) echo "allocate channel c${THREADKOUNT} type 'sbt_tape'" >> ${CMDFILE}
            echo "       PARMS= 'ENV=(NB_ORA_CLASS=${NB_CLASS}," >> ${CMDFILE}
            echo "               NB_ORA_SERV=${NB_ORACLE_SERVER}," >> ${CMDFILE}
            echo "               NB_ORA_CLIENT=${NB_ORACLE_CLIENT}," >> ${CMDFILE}
            echo "               NLS_LANG=${NB_NLS_LANG})'" >> ${CMDFILE}
            echo "               format '${NB_FILE_FMT}';" >> ${CMDFILE};;
    esac
  done

 case ${BKUP_TYPE} in
     HOT) if [ ${COMPRESS_BKUP} = 'Y' ]; then
            echo "  backup as compressed backupset " >> ${CMDFILE}
          else
            echo "  backup " >> ${CMDFILE}
          fi
          echo "    incremental level ${INC_FULL}" >> ${CMDFILE}
          echo "    filesperset ${NB_FILES_PER_SET}" >> ${CMDFILE}
          echo "    format '${NB_FILE_FMT}'" >> ${CMDFILE}
          echo "    skip offline" >> ${CMDFILE}
          echo "    tag ${NB_TAG_NAME}" >> ${CMDFILE}
          echo "    database;" >> ${CMDFILE};;
    COLD) if [ ${COMPRESS_BKUP} = 'Y' ]; then
            echo "  backup as compressed backupset " >> ${CMDFILE}
          else
            echo "  backup " >> ${CMDFILE}
          fi
          echo "    filesperset ${NB_FILES_PER_SET}" >> ${CMDFILE}
          echo "    format '${NB_FILE_FMT}'" >> ${CMDFILE}
          echo "    skip offline" >> ${CMDFILE}
          echo "    tag ${NB_TAG_NAME}" >> ${CMDFILE}
          echo "    database;" >> ${CMDFILE};;
    ARCH) echo "  sql 'alter system archive log current';" >> ${CMDFILE}
          if [ ${COMPRESS_BKUP} = 'Y' ]; then
            echo "  backup as compressed backupset " >> ${CMDFILE}
          else
            echo "  backup " >> ${CMDFILE}
          fi
          echo "    filesperset ${NB_FILES_PER_SET}" >> ${CMDFILE}
          echo "    format '${NB_FILE_FMT}'" >> ${CMDFILE}
#          echo "    tag ${NB_TAG_NAME}" >> ${CMDFILE}
          echo "    archivelog all delete input;" >> ${CMDFILE};;
  esac

  THREADKOUNT=0
  while [ ${THREADKOUNT} -lt ${NB_CHANNELS} ]
  do
    THREADKOUNT=`expr ${THREADKOUNT} + 1`

    if [ ${THREADKOUNT} -eq ${NB_CHANNELS} ] ; then
      echo "backup current controlfile;" >> ${CMDFILE}
    fi

    echo "release channel c${THREADKOUNT};" >> ${CMDFILE}
  done


  echo "}" >> ${CMDFILE}
  echo "report schema;" >> ${CMDFILE};
  echo "exit;" >> ${CMDFILE}

  cat ${CMDFILE} | ${LOG_CMD_MAIN}

  echo " " | ${LOG_CMD_MAIN}
  echo "Done creating RMAN Command file for backing up database or archivelogs." | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}
}



#
# Generate the RMAN command file for resyncing catalog with target
#

fn_gen_sync()
{
  echo " " | ${LOG_CMD_MAIN}
  echo "Create RMAN Command file for RESYNC of database with Catalog" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "connect target;" > ${SYNC_CMD_FILE}
  echo "connect catalog ${RMANID}/${RMANPWD}@${RMANSID};" >> ${SYNC_CMD_FILE}
  echo "resync catalog;" >> ${SYNC_CMD_FILE}
  echo "exit;" >> ${SYNC_CMD_FILE}

  cat ${SYNC_CMD_FILE} | ${LOG_CMD_MAIN}

  echo " " | ${LOG_CMD_MAIN}
  echo "Done creating RMAN Command file for RESYNC of database with Catalog" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}
}




#
# Check manually passed values and current date to determine whether to run a daily or monthly backup
#

fn_set_backup_timing ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Checking tomorrow's date!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "set heading off" > ${SQL_FILE}
  echo "set pagesize 0" >> ${SQL_FILE}
  echo "set feedback off" >> ${SQL_FILE}
  echo "set tab off" >> ${SQL_FILE}
  echo "set trimout on" >> ${SQL_FILE}
  echo "set linesize 50" >> ${SQL_FILE}
  echo "select trim(to_char(sysdate+1, 'dd'))" >> ${SQL_FILE}
  echo "  from dual;" >> ${SQL_FILE}

  TOMORROW=`cat ${SQL_FILE} | ${SQLPLUS} -s ${DBADMINID}/${DBADMINPWD}`

  echo "set heading off" > ${SQL_FILE}
  echo "set pagesize 0" >> ${SQL_FILE}
  echo "set feedback off" >> ${SQL_FILE}
  echo "set tab off" >> ${SQL_FILE}
  echo "set trimout on" >> ${SQL_FILE}
  echo "set linesize 50" >> ${SQL_FILE}
  echo "select trim(to_char(sysdate, 'D'))" >> ${SQL_FILE}
  echo "  from dual;" >> ${SQL_FILE}

  DAY=`cat ${SQL_FILE} | ${SQLPLUS} -s ${DBADMINID}/${DBADMINPWD}`


  if [ ${BKUP_TIMING} = 'DAILY' ] ; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Run DAILY backup policy manually" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    MONTHLY='FALSE'
  elif [ ${BKUP_TIMING} = 'WEEKLY' ] ; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Run WEEKLY backup policy manually" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    MONTHLY='FALSE'
  elif [ ${BKUP_TIMING} = 'MONTHLY' ] ; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Run MONTHLY backup policy manually" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    MONTHLY='TRUE'
  elif [ ${TOMORROW} = '01' ]; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Today is the last day of the month - Run MONTHLY backup policy." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    BKUP_TIMING='MONTHLY'
  elif [ ${DAY} = ${WEEKLY_BACKUP_DAY} ]; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Today is WEEKLY backup policy." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    BKUP_TIMING='WEEKLY'
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Run DAILY backup policy." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    BKUP_TIMING='DAILY'
  fi

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
# Check database for being in ARCHIVELOG mode
#

fn_check_logmode ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Verifying database is in archivelog mode!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo 'set heading off' > ${SQL_FILE}
  echo 'set pagesize 0' >> ${SQL_FILE}
  echo 'set feedback off' >> ${SQL_FILE}
  echo 'set tab off' >> ${SQL_FILE}
  echo 'set trimout on' >> ${SQL_FILE}
  echo 'set linesize 100' >> ${SQL_FILE}
  echo 'select trim(LOG_MODE)' >> ${SQL_FILE}
  echo '  from v$database;' >> ${SQL_FILE}

  LOG_MODE=`cat ${SQL_FILE} | ${SQLPLUS} -s ${DBADMINID}/${DBADMINPWD}`

  if [ ${LOG_MODE} = 'NOARCHIVELOG' ] ; then
    echo " " | ${LOG_CMD_MAIN}
    echo " Database is not in ARCHIVELOG mode. RMAN ${BKUP_TYPE} Backup not possible." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    fn_clear_backup_flag
    export BKUP_FAIL_STAT='Database is not in ARCHIVELOG mode - cannot perform hot backup'
    export BKUP_SUCC_FAIL='FAILED'
    fn_finish_status
    fn_script_failure_processing
    exit 1
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Database is in ARCHIVELOG mode. RMAN ${BKUP_TYPE} Backup may continue." | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi
}



#
# Check database for what NLS_CHARACTERSET needs to be passed to Netbackup
#

fn_set_nls_char_set ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Retrieving NLS Parameters for Netbackup!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "set heading off" > ${SQL_FILE}
  echo "set pagesize 0" >> ${SQL_FILE}
  echo "set feedback off" >> ${SQL_FILE}
  echo "set tab off" >> ${SQL_FILE}
  echo "set trimout on" >> ${SQL_FILE}
  echo "set linesize 100" >> ${SQL_FILE}
  echo "select trim(NLS_LANG || '_' || NLS_TERR || '.' || NLS_CHARSET)" >> ${SQL_FILE}
  echo "  from (select trim(value) NLS_LANG" >> ${SQL_FILE}
  echo "          from nls_database_parameters" >> ${SQL_FILE}
  echo "         where upper(parameter) = 'NLS_LANGUAGE') LANG," >> ${SQL_FILE}
  echo "       (select trim(value) NLS_TERR" >> ${SQL_FILE}
  echo "          from nls_database_parameters" >> ${SQL_FILE}
  echo "         where upper(parameter) = 'NLS_TERRITORY') TERR," >> ${SQL_FILE}
  echo "       (select trim(value) NLS_CHARSET" >> ${SQL_FILE}
  echo "          from nls_database_parameters" >> ${SQL_FILE}
  echo "         where upper(parameter) = 'NLS_CHARACTERSET') CHARSET;" >> ${SQL_FILE}

  NB_NLS_LANG=`cat ${SQL_FILE} | ${SQLPLUS} -s ${DBADMINID}/${DBADMINPWD}`

  echo " " | ${LOG_CMD_MAIN}
  echo " Retrieved NLS Parameters for Netbackup as ${NB_NLS_LANG}!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}
}



#
#
# Print out the variables set in run to primary log
#

fn_log_vars ()
{
  echo "SQLPLUS: ${SQLPLUS}" | ${LOG_CMD_MAIN}
  echo "SRVCTL: ${SRVCTL}" | ${LOG_CMD_MAIN}
  echo "RMAN: ${RMAN}" | ${LOG_CMD_MAIN}
  echo "ORACLE_SID: ${ORACLE_SID}" | ${LOG_CMD_MAIN}
  echo "ORACLE_HOME: ${ORACLE_HOME}" | ${LOG_CMD_MAIN}
  echo "ORACLE_USER: ${ORACLE_USER}" | ${LOG_CMD_MAIN}
  echo "SCRIPT: ${SCRIPT}" | ${LOG_CMD_MAIN}
  echo "NB_ORA_CLASS: ${NB_CLASS}" | ${LOG_CMD_MAIN}
  echo "NB_ORA_SERV: ${NB_ORACLE_SERVER}" | ${LOG_CMD_MAIN}
  echo "NB_ORA_CLIENT: ${NB_ORACLE_CLIENT}" | ${LOG_CMD_MAIN}
  echo "NB_INCR_LVL: ${INC_FULL}" | ${LOG_CMD_MAIN}
  echo "NB_FILES_PER_SET: ${NB_FILES_PER_SET}" | ${LOG_CMD_MAIN}
  echo "NB_NLS_LANG: ${NB_NLS_LANG}" | ${LOG_CMD_MAIN}
  echo "NB_FORMAT: ${NB_FILE_FMT}" | ${LOG_CMD_MAIN}
  echo "NB_TAG: ${NB_TAG_NAME}" | ${LOG_CMD_MAIN}
  echo "RMAN_CATALOG: ${RMANID}" | ${LOG_CMD_MAIN}
  echo "RMAN_CATALOG_DATABASE: ${RMANSID}" | ${LOG_CMD_MAIN}
  echo "BACKUP_TIMING: ${BKUP_TIMING}" | ${LOG_CMD_MAIN}
  echo "WEEKLY_BACKUP_DAY: ${WEEKLY_BACKUP_DAY}" | ${LOG_CMD_MAIN}
  echo "BACKUP_TYPE: ${BKUP_TYPE}" | ${LOG_CMD_MAIN}
  echo "DISK_TAPE: ${DISK_TAPE}" | ${LOG_CMD_MAIN}
  echo "RAC_NORAC: ${RAC_NORAC}" | ${LOG_CMD_MAIN}
  echo "RAC_DBNAME: ${RAC_DBNAME}" | ${LOG_CMD_MAIN}
  echo "ORACLE_OWNER: ${ORACLE_OWNER}" | ${LOG_CMD_MAIN}
  echo "ORACLE_GROUP: ${ORACLE_GROUP}" | ${LOG_CMD_MAIN}
  echo "DB_REGION: ${DB_REGION}" | ${LOG_CMD_MAIN}
  echo "COMPRESS_BKUP: ${COMPRESS_BKUP}" | ${LOG_CMD_MAIN}
}



#
# Run the rman command to resync the database with the catalog
#

fn_run_sync()
{
  export TS=`date '+%d-%b-%Y %H:%M'`
  echo " " | ${LOG_CMD_MAIN}
  echo " Initiated RMAN for ${BKUP_TYPE} backup of ${DBNAME} database at ${TS}!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${RMAN} cmdfile ${SYNC_CMD_FILE} log ${CURR_SYNC_LOG}
  VALUE_RET=$?

  cat ${CURR_SYNC_LOG} | ${LOG_CMD_MAIN}

  if [ ${VALUE_RET} = 0 ]; then
    RESYNC_CATALOG='Y'
    echo " " | ${LOG_CMD_MAIN}
    echo " Catalog resync completed SUCCESSFULLY!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  else
    sleep 300
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " First Catalog Resync failed, waited 5 min and trying again at ${TS}!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}

    ${RMAN} cmdfile ${SYNC_CMD_FILE} log ${CURR_SYNC_LOG}
    VALUE_RET=$?

    cat ${CURR_SYNC_LOG} | ${LOG_CMD_MAIN}

    if [ ${VALUE_RET} = 0 ]; then
      RESYNC_CATALOG='Y'
      echo " " | ${LOG_CMD_MAIN}
      echo " Second Catalog resync completed SUCCESSFULLY!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
    else
      export TS=`date '+%d-%b-%Y %H:%M'`
      export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`
      RESYNC_CATALOG='N'
      echo " " | ${LOG_CMD_MAIN}
      echo " Catalog resync FAILED!" | ${LOG_CMD_MAIN}
      echo " Backup job FAILED at ${TS}." | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      export BKUP_SUCC_FAIL='FAILED'
      export BKUP_FAIL_STAT='RMAN catalog resync failed'
      fn_finish_status
      fn_clear_backup_flag
      fn_script_failure_processing
      exit 1
    fi
  fi
}



#
# Run the rman command to backup the database
#

fn_run_backup()
{
  export TS=`date '+%d-%b-%Y %H:%M'`
  echo " " | ${LOG_CMD_MAIN}
  echo " Initiated RMAN for a ${BKUP_TIMING} ${BKUP_TYPE} backup of ${DBNAME} database at ${TS}!" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  ${RMAN} cmdfile ${CMDFILE} log ${CURR_LOG}
  VALUE_RET=$?

  cat ${CURR_LOG} | ${LOG_CMD_MAIN}

  export TS=`date '+%d-%b-%Y %H:%M'`
  export BKUP_FINISH_DATE=`date '+%d-%b-%Y %H:%M'`

  if [ ${VALUE_RET} = 0 ] ; then
    if [ ${BKUP_TYPE} = 'HOT' ]; then
      if [ ${BKUP_TIMING} = 'MONTHLY' ] ||[ ${BKUP_TIMING} = 'WEEKLY' ] || [ ${RMAN_ALWAYS_INCLUDE_ARCH} = 'Y' ]; then
        echo " " | ${LOG_CMD_MAIN}
        echo " Hot Backup completed SUCCESSFULLY for ${DBNAME} on ${TS} starting Archivelog Backup!" | ${LOG_CMD_MAIN}
        echo " " | ${LOG_CMD_MAIN}
        export BKUP_SUCC_FAIL='SUCCESSFUL'
        export BKUP_FAIL_STAT='RMAN backup successful'
        fn_finish_status
      else
        echo " " | ${LOG_CMD_MAIN}
        echo " Backup job SUCCESSFULL for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
        echo " " | ${LOG_CMD_MAIN}
        export BKUP_SUCC_FAIL='SUCCESSFUL'
        export BKUP_FAIL_STAT='RMAN backup successful'
        fn_finish_status
      fi
    else
      echo " " | ${LOG_CMD_MAIN}
      echo " Backup job SUCCESSFULL for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
      echo " " | ${LOG_CMD_MAIN}
      export BKUP_SUCC_FAIL='SUCCESSFUL'
      export BKUP_FAIL_STAT='RMAN backup successful'
      fn_finish_status
    fi
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Backup job FAILED for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    export BKUP_SUCC_FAIL='FAILED'
    export BKUP_FAIL_STAT='RMAN backup failed'
    fn_finish_status
    fn_clear_backup_flag
    fn_script_failure_processing
    exit 1
  fi
}



#
# Remove old logs from database RMAN directory
#

fn_cleanup ()
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Removing old RMAN logs for ${DBNAME}!" | $LOG_CMD_MAIN
  echo " " | ${LOG_CMD_MAIN}
  find ${LOG_DIR} -name "*COLD*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  find ${LOG_DIR} -name "*HOT*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  find ${LOG_DIR} -name "*MONTHLY*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  find ${LOG_DIR} -name "*WEEKLY*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  find ${LOG_DIR} -name "*ARCH*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  find ${LOG_DIR} -name "*report*.log" -type f -mtime +7 -print -exec ${RM} -f {} \;> /dev/null
  chmod 660 ${LOG_DIR}/*.*
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
       '${BKUP_TYPE}',
       nvl('${INC_FULL}',0),
       '${BKUP_TIMING}',
       '${DISK_TAPE}',
       TO_DATE('${BKUP_START_DATE}', 'dd-mon-yyyy HH24:MI'),
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
    echo $?
    echo " " | ${LOG_CMD_MAIN}
    echo " FAILED when updating row in backup status table to indicate RAC status!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Successfully updated row in backup status table to indicate RAC status!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi

}



#
# Update the row for backup status at the end of the backup job
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
       set finish_time = TO_DATE('${BKUP_FINISH_DATE}', 'dd-mon-yyyy HH24:MI'),
           backup_status = '${BKUP_SUCC_FAIL}',
           backup_status_message = '${BKUP_FAIL_STAT}'
     where instance_name = '${ORACLE_SID}'
       and dbname = '${RAC_DBNAME}'
       and server = '${NB_ORACLE_CLIENT}'
       and db_type = '${PGM_LOC}'
       and rac_norac = decode('${RAC_NORAC}', 'YES', 'RAC',
                              'NO','NORAC',
                              'UKNWN')
       and backup_type = '${BKUP_TYPE}'
       and incremental_level = nvl('${INC_FULL}', 0)
       and daily_monthly = '${BKUP_TIMING}'
       and disk_tape = '${DISK_TAPE}'
       and start_time = TO_DATE('${BKUP_START_DATE}', 'dd-mon-yyyy HH24:MI')
       and db_region = '${DB_REGION}';
    commit;
  exit
EOT

  if [ $? -ne 0 ]; then
    echo $?
    echo " " | ${LOG_CMD_MAIN}
    echo " FAILED when updating row in backup status table!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  else
    echo " " | ${LOG_CMD_MAIN}
    echo " Successfully updated row in backup status table to indicate completion status!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
  fi

}



#
#  Run archive backup if a weekly or monthly  hot backup was requested so that the
# associated archivelogs are retained at a weekly/monthly retention
# or run archive backup if RMAN_ALWAYS_INCLUDE_ARCH flag set to Y  (set in .<db>_env file)
#


fn_post_backup_arc ()

{
   if [ ${BKUP_TIMING} = 'MONTHLY' ] || [ ${BKUP_TIMING} = 'WEEKLY' ] ||  [ ${RMAN_ALWAYS_INCLUDE_ARCH} = 'Y' ]; then
        fn_clear_backup_flag
        BKUP_TYPE='ARCH'
        NB_TAG_NAME=${BKUP_TIMING}_${BKUP_TYPE}_BACKUP_`date +%H`
        case ${DISK_TAPE} in
          DISK) NB_FILE_FMT=${BKDIR}/${ARCH_FORMAT};;
             *) NB_FILE_FMT=${ARCH_FORMAT};;
        esac
        NB_FILES_PER_SET=10
        SCRIPT_NAME=rman_${BKUP_TYPE}
        CURR_LOG=${LOG_DIR}/${SCRIPT_NAME}.log
        CMDFILE=${ARCH_CMD_FILE}
        export BKUP_START_DATE=`date '+%d-%b-%Y %H:%M'`
        fn_start_status
        fn_update_rac_status
        fn_log_vars
        fn_gen_cmd
        fn_run_backup
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
    echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
    echo "Aborting!"
    exit 1
  fi

  if [ -z $2 ]; then
    echo "DB Name was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
    echo "Aborting!"
    exit 1
  fi

  if [ -z $3 ]; then
    echo "DB Level (DEV/MOD/PROD) was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
    echo "Aborting!"
    exit 1
  else
    case $3 in
       DEV) ;;
       MOD) ;;
      PROD) ;;
         *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
            echo "Correct format for calling is : "
            echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
            echo "Aborting!"
            exit 1;;
    esac
  fi

  if [ -z $4 ]; then
    echo "Backup type (HOT/COLD/ARCH) was not passed correctly."
    echo "Correct format for calling is : "
    echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
    echo "Aborting!"
    exit 1
  else
    case $4 in
       HOT) if [ -z $5 ]; then
              echo "Backup Level (# between 0 and 6) was not passed correctly."
              echo "Correct format for calling is : "
              echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
              echo "Aborting!"
              exit 1
            else
              case $5 in
                [0-6]) if [ -z  $6 ]; then
                         export BKUP_TIMING='DEFAULT'
                         export DISK_TAPE='TAPE'
                       else
                         case $6 in
                             DAILY) if [ -z $7 ]; then
                                      export BKUP_TIMING=$6
                                      export DISK_TAPE='TAPE'
                                    else
                                      export BKUP_TIMING=$6
                                      export DISK_TAPE=$7
                                    fi;;
                           WEEKLY) if [ -z $7 ]; then
                                     export BKUP_TIMING=$6
                                     export DISK_TAPE='TAPE'
                                  else
                                     export BKUP_TIMING=$6
                                     export DISK_TAPE=$7
                                   fi ;;
                           MONTHLY) if [ -z $7 ]; then
                                      export BKUP_TIMING=$6
                                      export DISK_TAPE='TAPE'
                                    else
                                      export BKUP_TIMING=$6
                                      export DISK_TAPE=$7
                                    fi;;
                              DISK) export BKUP_TIMING='DEFAULT'
                                    export DISK_TAPE=$6;;
                              TAPE) export BKUP_TIMING='DEFAULT'
                                    export DISK_TAPE=$6;;
                                 *) export BKUP_TIMING='DEFAULT'
                                    export DISK_TAPE='TAPE';;
                         esac
                       fi;;
                    *) echo "Backup Level (# between 0 and 6) was not passed correctly."
                       echo "Correct format for calling is : "
                       echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
                       echo "Aborting!"
                       exit 1;;
              esac
            fi;;
      COLD) if [ -z $5 ]; then
              export BKUP_TIMING='DEFAULT'
              export DISK_TAPE='TAPE'
            else
               case $5 in
                   DAILY) if [ -z $6 ]; then
                            export BKUP_TIMING=$5
                            export DISK_TAPE='TAPE'
                          else
                            export BKUP_TIMING=$5
                            export DISK_TAPE=$6
                          fi;;
                  WEEKLY) if [ -z $6 ]; then
                            export BKUP_TIMING=$5
                            export DISK_TAPE='TAPE'
                          else
                            export BKUP_TIMING=$5
                            export DISK_TAPE=$6
                          fi ;;
                 MONTHLY) if [ -z $6 ]; then
                            export BKUP_TIMING=$5
                            export DISK_TAPE='TAPE'
                          else
                            export BKUP_TIMING=$5
                            export DISK_TAPE=$6
                          fi;;
                    DISK) export BKUP_TIMING='DEFAULT'
                          export DISK_TAPE=$5;;
                    TAPE) export BKUP_TIMING='DEFAULT'
                          export DISK_TAPE=$5;;
                       *) export BKUP_TIMING='DEFAULT'
                          export DISK_TAPE='TAPE';;
              esac
            fi;;
      ARCH) if [ -z $5 ]; then
              export BKUP_TIMING='DEFAULT'
              export DISK_TAPE='TAPE'
            else
               case $5 in
                   DAILY) if [ -z $6 ]; then
                            export BKUP_TIMING=$5
                            export DISK_TAPE='TAPE'
                          else
                            export BKUP_TIMING=$5
                            export DISK_TAPE=$6
                          fi;;
                  WEEKLY) if [ -z $6 ]; then
                            export BKUP_TIMING=$5
                            export DISK_TAPE='TAPE'
                          else
                            export BKUP_TIMING=$5
                            export DISK_TAPE=$6
                          fi ;;
                 MONTHLY) if [ -z $6 ]; then
                            export BKUP_TIMING=$5
                            export DISK_TAPE='TAPE'
                          else
                            export BKUP_TIMING=$5
                            export DISK_TAPE=$6
                          fi;;
                    DISK) export BKUP_TIMING='DEFAULT'
                          export DISK_TAPE=$5;;
                    TAPE) export BKUP_TIMING='DEFAULT'
                          export DISK_TAPE=$5;;
                       *) export BKUP_TIMING='DEFAULT'
                          export DISK_TAPE='TAPE';;
              esac
            fi;;
         *) echo "Backup type (HOT/COLD/ARCH) was not passed correctly."
            echo "Correct format for calling is : "
            echo "rman_backup.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <HOT/COLD/ARCH> <Incremental Level> <DAILY/WEEKLY/MONTHLY (Optional)> <DISK/TAPE (Optional)>."
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
  export BKUP_TYPE=$4
  export INC_FULL=$5
  export ORACLE_OWNER=oracle
  export ORACLE_GROUP=dba
  export COMPRESS_BKUP=N
  export DB_REGION=UKNWN
  export NB_ARCH_ORACLE_CLASS=NONE
  export NB_WEEKLY_ORACLE_CLASS=NONE
  export NB_DAILY_ORACLE_CLASS=NONE
  export NB_MONTHLY_ORACLE_CLASS=NONE
  export WEEKLY_BACKUP_DAY=NONE
  export DB_FILES_PER_SET=1
  export ARCH_FILES_PER_SET=10


#
# The below 3 environment sourcing lines are done in this manner on purpose
#   the .{DBNAME}_env file is sourced to get the proper ORACLE_HOME information for the database
#   the .server_environ file is then sourced to get the default values for variables and general setups
#   the .{DBNAME}_env file is then sourced a second time to do overrides of the defaults if needed
#

  . ${DBADMIN}/.${DBNAME}_env
  . `dirname $0`/../.server_environ
  . ${DBADMIN}/.${DBNAME}_env

#
#  The below section sets default values for parameters not always configured in the parameter file.
#



  if [ ${NB_WEEKLY_ORACLE_CLASS} = 'NONE' ]; then
        NB_WEEKLY_ORACLE_CLASS = ${NB_MONTHLY_ORACLE_CLASS}
  fi


  if [ ${WEEKLY_BACKUP_DAY} = 'NONE' ] ; then
     if [ ${PGM_LOC} = 'PROD' ]; then
        WEEKLY_BACKUP_DAY=7
     else
        WEEKLY_BACKUP_DAY=4
     fi
  fi




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

#
# The following code sets up one master output file that everything goes to
#

case ${BKUP_TYPE} in
   HOT) OUTF=${LOG_DIR}/call_rman_hot.sh.out
        SCRIPT=call_rman_hot.sh;;
  COLD) OUTF=${LOG_DIR}/call_rman_cold.sh.out
        SCRIPT=call_rman_cold.sh;;
  ARCH) OUTF=${LOG_DIR}/call_rman_arch.sh.out
        SCRIPT=call_rman_arch.sh;;
esac

{
  export TS=`date '+%d-%b-%Y %H:%M'`
  export BKUP_START_DATE=`date '+%d-%b-%Y %H:%M'`

  SCRIPT_NAME=rman_${BKUP_TYPE}

  MAIN_LOG=${LOG_DIR}/${SCRIPT_NAME}_${DBNAME}_`date +%Y%m%d%H%M`.log
  CURR_LOG=${LOG_DIR}/${SCRIPT_NAME}.log
  CURR_SYNC_LOG=${LOG_DIR}/rman_resync.log
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
  SRVCTL="$ORACLE_HOME/bin/srvctl"
  ORACLE_USER=`whoami`

  SQL_FILE=${DB_RMAN_DIR}/rman_sqlfile_${DBNAME}.sql
  SYNC_CMD_FILE=${DB_RMAN_DIR}/resync_${DBNAME}.rmc
  ARCH_CMD_FILE=${DB_RMAN_DIR}/arch_${DBNAME}.rmc
  HOT_CMD_FILE=${DB_RMAN_DIR}/hot_${DBNAME}.rmc
  COLD_CMD_FILE=${DB_RMAN_DIR}/cold_${DBNAME}.rmc

  ${RM} -f ${SYNC_CMD_FILE}
  ${RM} -f ${ARCH_CMD_FILE}
  ${RM} -f ${HOT_CMD_FILE}
  ${RM} -f ${COLD_CMD_FILE}
  ${RM} -f ${SQL_FILE}

#
# Call function to determine proper backup type
#
  fn_set_backup_timing

  case ${BKUP_TIMING} in
      DAILY) if [ ${NB_DAILY_ORACLE_CLASS} = 'NONE' ]; then
               echo "ERROR -Daily Netbackup Oracle class not set properly"  | ${LOG_CMD_MAIN}
               exit 1
             fi
             if [ ${BKUP_TYPE} = 'ARCH' ]; then
               if [ ${NB_ARCH_ORACLE_CLASS} = 'NONE' ]; then
                 NB_CLASS=${NB_DAILY_ORACLE_CLASS}
               else
                 NB_CLASS=${NB_ARCH_ORACLE_CLASS}
               fi
             else
               NB_CLASS=${NB_DAILY_ORACLE_CLASS}
             fi;;
     WEEKLY) if [ ${NB_WEEKLY_ORACLE_CLASS} = 'NONE' ]; then
               echo "ERROR -Weekly Netbackup Oracle class not set properly"  | ${LOG_CMD_MAIN}
               exit 1
             fi
             NB_CLASS=${NB_WEEKLY_ORACLE_CLASS}
             INC_FULL=0;;
    MONTHLY) if [ ${NB_MONTHLY_ORACLE_CLASS} = 'NONE' ]; then
               echo "ERROR -Monthly Netbackup Oracle class not set properly"  | ${LOG_CMD_MAIN}
               exit 1
             fi
             NB_CLASS=${NB_MONTHLY_ORACLE_CLASS}
             INC_FULL=0;;

  esac



  case ${BKUP_TYPE} in
     HOT) NB_FILE_FMT=${HOT_BKUP_FORMAT}
          NB_FILES_PER_SET=${DB_FILES_PER_SET}
          CMDFILE=${HOT_CMD_FILE};;
    COLD) NB_FILE_FMT=${COLD_BKUP_FORMAT}
          NB_FILES_PER_SET=${DB_FILES_PER_SET}
          CMDFILE=${COLD_CMD_FILE};;
    ARCH) NB_FILE_FMT=${ARCH_FORMAT}
          NB_FILES_PER_SET=${ARCH_FILES_PER_SET}
          CMDFILE=${ARCH_CMD_FILE};;
  esac

  case ${DISK_TAPE} in
    DISK) if [ ! -d ${BKDIR} ]; then
            echo "DISK Backup requested, but the backup directory of ${BKDIR} does not exist. Aborting!"
            exit 1
          else
            NB_FILE_FMT=${BKDIR}/${NB_FILE_FMT}
          fi;;
       *) ;;
  esac

  NB_TAG_NAME=${BKUP_TIMING}_${BKUP_TYPE}_BACKUP_`date +%H`

  ${RM} -f ${CMDFILE}

  ${RM} -f ${CURR_LOG}
  touch ${CURR_LOG}
  cat /dev/null > ${CURR_LOG}

  ${RM} -f ${CURR_SYNC_LOG}
  touch ${CURR_SYNC_LOG}
  cat /dev/null > ${CURR_SYNC_LOG}

#
#  Run Script
#

  fn_start_status

  export TS=`date '+%d-%b-%Y %H:%M'`

  echo "Starting ${BKUP_TYPE} backup of ${DBNAME} at ${TS}." | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  fn_check_dbstatus

  if [ ${BKUP_TYPE} != 'COLD' ]; then
    fn_check_logmode
  fi

  fn_check_backup_flag

  fn_set_nls_char_set

  fn_check_rac

  fn_update_rac_status

  fn_log_vars

  fn_gen_cmd

  fn_gen_sync

  fn_run_sync

  if [ ${RESYNC_CATALOG} = 'Y' ]; then

    if [ ${BKUP_TYPE} = 'COLD' ]; then
      # Place database in mounted state for cold backup
      fn_mount_db
    fi

    # Run requested Backup
    fn_run_backup
    if [ ${BKUP_TYPE} != 'ARCH' ]; then
      fn_backup_controlfile
    fi

    # Run archive backup if a weekly or monthly  hot backup was requested so that the
    # associated archivelogs are retained at a weekly/monthly retention
    # or run archive backup if RMAN_ALWAYS_INCLUDE_ARCH flag set to Y  (set in .<db>_env file)
    if [ ${BKUP_TYPE} = 'HOT' ]; then
      fn_post_backup_arc
    elif [ ${BKUP_TYPE} = 'COLD' ]; then
      fn_open_db
    fi
  fi

  fn_cleanup

  fn_clear_backup_flag

  fn_write_finish_time

} > ${OUTF}
exit 0
