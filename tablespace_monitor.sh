#!/bin/ksh
#
# Script        : tablespace_monitor.sh
#
# Usage         : tablespace_monitor.sh   <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>
#
# Purpose       : To monitor tablespace
#
# REVISION HISTORY:
# Rajwinder Sharma          : 10-May-2017
# -------------------
#
###################################################################

SCRIPT_NAME=tablespace_monitor


fn_db_status_check()
{
echo "Checking database status..." > $LOGFILE
sqlplus -s /nolog >>$LOGFILE << EOF
 connect ${DBADMINID}/${DBADMINPWD}

 whenever sqlerror exit sql.sqlcode
    whenever oserror exit 9

        set feedback off
        set pause off
        set trimspool on
        set heading off
select 'Database Status is : '||open_mode from v\$database;
show user;
exit
EOF

if [ $? -ne 0 ]
  then
    echo "Database is down">>$ERRFILE
    exit 1
fi

}



fn_tbs_monitor_check()
{

echo "Executing TABLESAPCE MGNT PCKG" >> $LOGFILE
echo "" >> $LOGFILE

sqlplus -s /nolog  >>$LOGFILE <<EOF
connect ${DBADMINID}/${DBADMINPWD}

whenever sqlerror exit sql.sqlcode
    whenever oserror exit 9

set feed on;
set line 200 pages 500
set echo on;
set serveroutput on format wrapped;
EXEC TBS_MGNMNT.AUTOTBS_MON;
exit
EOF

if [ $? -ne 0 ]
  then
    echo "Errors in executing TBS_MGNMNT.AUTOTBS_MON ">>$ERRFILE
    exit 1
fi

}


fn_tbs_log_cleanup()
{
find ${DBADMIN}/logs -name "tablespace_monitor*.log" -mtime +30 -exec rm -f {} \;
}

#
#SEND EMAIL  TO A MAILING GROUP
#
fn_send_email()
{
SUBJECT_TXT="Tablespace Monitor $DBNAME"
cat $ERRFILE >> $LOGFILE
SIZE=$(ls -ltr $LOGFILE  | tr -s ' ' | cut -d ' ' -f 5)
if [ $SIZE != 156 ]
then

cat $LOGFILE | /bin/mailx  -s "${SUBJECT_TXT}" ${PRIMARY_SUPPORT_EMAIL},"#MMCMarshGITO-GSDSharedServices-NAM-DBA@hub.wmmercer.com"
fi
}


 # Set Environment Variables

if [ -z $1 ]; then
    echo "Database admin directory was not passed correctly."
    echo "Correct format for calling is : "
    echo "gather_stats.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
    echo "Aborting!"
    exit 1
  fi

  if [ -z $2 ]; then
    echo "DB Name was not passed correctly."
    echo "Correct format for calling is : "
    echo "gather_stats.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
    echo "Aborting!"
    exit 1
  fi

  if [ -z $3 ]; then
    echo "DB Level (DEV/MOD/PROD) was not passed correctly."
    echo "Correct format for calling is : "
    echo "gather_stats.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
    echo "Aborting!"
    exit 1
  else
    case $3 in
       DEV) ;;
       MOD) ;;
      PROD) ;;
         *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
            echo "Correct format for calling is : "
            echo "gather_stats.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
            echo "Aborting!"
            exit 1;;
    esac
  fi



  export DBADMIN=$1
  export DBNAME=$2
  export PGM_LOC=$3
  export DB_REGION=NA

  . ${DBADMIN}/.${DBNAME}_env

  . `dirname $0`/../.server_environ

  . ${DBADMIN}/.${DBNAME}_env


 # Create Log Output Files
DATE=`date '+%Y.%m.%d.%H%M%S'`
LOGFILE=${DBADMIN}/logs/${SCRIPT_NAME}.${DBNAME}.${DATE}.log
ERRFILE=${DBADMIN}/logs/${SCRIPT_NAME}.${DBNAME}.${DATE}.err
#exec >> ${LOGFILE} 2>> ${ERRFILE}
touch ${LOGFILE}
touch ${ERRFILE}
# Change permissions on log and error file.
chmod 640 ${LOGFILE}
chmod 640 ${ERRFILE}


#
#  Run Script
#

fn_db_status_check
fn_tbs_monitor_check
fn_tbs_log_cleanup
fn_send_email

exit 0
