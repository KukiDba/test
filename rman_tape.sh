#!/bin/ksh
#
# Script Name: rman_tape.sh
# Script Purpose: Find tapes need for RMAN restore
# Usage:  rman_tape.sh 
#
# Prompts:    
#             DBNAME            - Name of the database to restore
#             DEV/MOD/PROD      - Database level to determine which RMAN catalog to use
#             DISK/TAPE         - Original backup to disk or tape
#             RESTORE DATE      - Date to restore from with format 'MM/DD/YYYY'
#                                  if omitted or incorrectly entered the default is current
#
# 10/12/2008  Jeff Wunsch   Created

#
# CD to the Users HOME Directory
#
cd `dirname $0`

#
# FUNCTIONS
#

#
# Query RMAN catalog for last full backup date
#

fn_last_full_backup () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Query RMAN catalog for last full backup" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "set pages 0" > ${SQL_FILE}
  echo "set lines 150" >> ${SQL_FILE}
  echo "set verify off" >> ${SQL_FILE}
  echo "set timing off" >> ${SQL_FILE}
  echo "set feedback off" >> ${SQL_FILE}
  echo "set echo off" >> ${SQL_FILE}
  echo "select " >> ${SQL_FILE}
  echo "  to_char(max(a.start_time),'MM/DD/RRRR')" >> ${SQL_FILE}
  echo "from" >> ${SQL_FILE}
  echo "  rc_backup_piece a," >> ${SQL_FILE}
  echo "  rc_database b" >> ${SQL_FILE}
  echo "where" >> ${SQL_FILE}
  echo "  a.DB_ID = b.DBID and" >> ${SQL_FILE}
  echo "  a.DB_KEY = b.DB_KEY and" >> ${SQL_FILE}
  echo "  a.start_time  <= to_date('${REST_DATE}','MM/DD/RRRR')+1 and" >> ${SQL_FILE}
  echo "  (a.HANDLE like 'hot%' or a.HANDLE like 'cold%') and" >> ${SQL_FILE}
  echo "  backup_type = 'D' and" >> ${SQL_FILE}
  echo "  b.name = upper('${DBNAME}');" >> ${SQL_FILE}
 
  LAST_FULL_BACKUP=`cat ${SQL_FILE} | ${SQLPLUS} -s ${RMANID}/${RMANPWD}@${RMANSID}`

  echo "Last full backup of ${DBNAME} is ${LAST_FULL_BACKUP}"


}

#
## Find tapes from tape backup
#

fn_rman_tape () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Query RMAN catalog for tapes required for restore" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "set pages 0" > ${SQL_FILE}
  echo "set lines 150" >> ${SQL_FILE}
  echo "set verify off" >> ${SQL_FILE}
  echo "set timing off" >> ${SQL_FILE}
  echo "set feedback off" >> ${SQL_FILE}
  echo "set echo off" >> ${SQL_FILE}
  echo "select " >> ${SQL_FILE}
  echo "  distinct(a.MEDIA)" >> ${SQL_FILE}
  echo "from" >> ${SQL_FILE}
  echo "  rc_backup_piece a," >> ${SQL_FILE}
  echo "  rc_database b" >> ${SQL_FILE}
  echo "where" >> ${SQL_FILE}
  echo "  a.DB_ID = b.DBID and" >> ${SQL_FILE}
  echo "  a.DB_KEY = b.DB_KEY and" >> ${SQL_FILE}
  echo "  a.start_time between to_date('${LAST_FULL_BACKUP}','MM/DD/RRRR') and to_date('${REST_DATE}','MM/DD/RRRR') and" >> ${SQL_FILE}
  echo "  b.name = upper('${DBNAME}')" >> ${SQL_FILE}
  echo "order by a.MEDIA;" >> ${SQL_FILE}
 
  cat ${SQL_FILE} | ${SQLPLUS} -s ${RMANID}/${RMANPWD}@${RMANSID} > ${RMAN_TAPE_LIST}

  echo ""
  echo "Required Tapes from ${DBNAME} for restore date ${REST_DATE}"
  cat ${RMAN_TAPE_LIST}
  echo ""
  echo ""


}

#
#
# Query RMAN catalog for backup files
#

fn_rman_files () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Query RMAN catalog for file names" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  echo "set pages 0" > ${SQL_FILE}
  echo "set lines 150" >> ${SQL_FILE}
  echo "set verify off" >> ${SQL_FILE}
  echo "set timing off" >> ${SQL_FILE}
  echo "set feedback off" >> ${SQL_FILE}
  echo "set echo off" >> ${SQL_FILE}
  echo "select " >> ${SQL_FILE}
  echo "  a.HANDLE" >> ${SQL_FILE}
  echo "from" >> ${SQL_FILE}
  echo "  rc_backup_piece a," >> ${SQL_FILE}
  echo "  rc_database b" >> ${SQL_FILE}
  echo "where" >> ${SQL_FILE}
  echo "  a.DB_ID = b.DBID and" >> ${SQL_FILE}
  echo "  a.DB_KEY = b.DB_KEY and" >> ${SQL_FILE}
  echo "  a.start_time between to_date('${LAST_FULL_BACKUP}','MM/DD/RRRR') and to_date('${REST_DATE}','MM/DD/RRRR') and" >> ${SQL_FILE}
  echo "  b.name = upper('${DBNAME}');" >> ${SQL_FILE}
 
  cat ${SQL_FILE} | ${SQLPLUS} -s ${RMANID}/${RMANPWD}@${RMANSID} > ${RMAN_FILE_LIST}

}

#
#
# Query NetBackup catalog for tapes
#

fn_rman_disk () 
{
  echo " " | ${LOG_CMD_MAIN}
  echo " Query NetBackup catalog for tapes required for restore" | ${LOG_CMD_MAIN}
  echo " " | ${LOG_CMD_MAIN}

  cat ${RMAN_FILE_LIST} | while read LINE;
  do
    /usr/openv/netbackup/bin/bpclntcmd -ml /${LINE} -ct Oracle -s ${LAST_FULL_BACKUP} -e ${REST_DATE} >> ${RMAN_TAPE_LIST}
  done

  echo ""
  echo "Required Tapes from ${DBNAME} for restore date ${REST_DATE}"
  cat ${RMAN_TAPE_LIST} | awk '{print $3}' | sort -u | grep -v `uname -n`
  echo ""
  echo ""


}


#####################################################################
#                            MAIN CODE                              #
#####################################################################

#
# Check input variables
#

clear
echo "******************************************************************"
echo " Restore Tape Parameters:"
echo "******************************************************************"
echo " "
#echo "DB Admin Directory:  \c"
#read DBADMIN
#  if [ -z $DBADMIN ]; then 
#    echo "Database admin directory was not passed correctly."
#    echo "Aborting!"
#    exit 1
#  fi
   
echo "DB Name:  \c"
read DBNAME
  if [ -z $DBNAME ]; then 
    echo "DB Name was not passed correctly."
    echo "Aborting!"
    exit 1
  fi

echo "DB Environment (DEV/MOD/PROD):  \c"
typeset -u PGM_LOC
read PGM_LOC
  if [ -z $PGM_LOC ]; then 
    echo "DB Level (DEV/MOD/PROD) was not passed correctly."
    echo "Aborting!"
    exit 1
  else
    case $PGM_LOC in
       DEV) ;;
       MOD) ;;
      PROD) ;;
         *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
            echo "Aborting!"
            exit 1;;
    esac
  fi

#echo "Original Media format TAPE/DISK (Default: TAPE):  \c"
#typeset -u BKUP_MEDIA
#read BKUP_MEDIA
#  if [ -z $BKUP_MEDIA ]; then 
#    echo "Media format (DISK/TAPE not passed correctly."
#    echo "Aborting!"
#    exit 1
#  else
#    case $BKUP_MEDIA in
#      DISK) ;;
#      TAPE) ;;
#         *) echo "Media format (DISK/TAPE) not passed correctly."
#         *) echo "Media format (DISK/TAPE) not passed correctly."
#            echo "Aborting!"
#            exit 1;;
#    esac
#  fi

BKUP_MEDIA=DISK

echo "Restore Date (Format: MM/DD/YYYY, Default: Current):  \c"
read REST_DATE
  if [ -z $REST_DATE ]; then 
    export REST_DATE=`date '+%m/%d/%Y'` 
    echo "Restore Date Not Passed, using current date: $REST_DATE."
  fi

#echo ""
#typeset -u CONTINUE
#echo "Continue (Y/N):  \c"
#read CONTINUE
#  if [ -z $CONTINUE ]; then 
#    echo "Aborting!"
#    exit 1
#  else
#    case $CONTINUE in
#         Y) ;;
#         N) ;;
#         *) echo "Aborting!"
#            exit 1;;
#    esac
#  fi


#  . ${DBADMIN}/.${DBNAME}_env

  . `dirname $0`/../.server_environ

  typeset -u ${DBNAME}

#  DB_RMAN_DIR=${DBADMIN}/rman/work
DB_RMAN_DIR=/tmp
  if [ ! -d ${DB_RMAN_DIR} ]; then
     mkdir -p ${DB_RMAN_DIR}
     if [ $? -ne 0 ]; then
        echo " Error creating log directory ${DB_RMAN_DIR}. Aborting!/n"
        exit 1
     fi
  fi
  LOG_DIR=${DB_RMAN_DIR}

  SQLPLUS="$ORACLE_HOME/bin/sqlplus"
  ORACLE_USER=`whoami`

  if [ ${ORACLE_USER} -ne 'oracle' ]; then
     echo "Must be logged in as oracle user.  Aborting!"
     exit 1
  fi
  
  RMAN_FILE_LIST=${DB_RMAN_DIR}/rman_file_list_${DBNAME}.lst
  RMAN_TAPE_LIST=${DB_RMAN_DIR}/rman_tape_list_${DBNAME}.lst
  SQL_FILE=${DB_RMAN_DIR}/sql_file_${DBNAME}.sql
  
  rm -f ${RMAN_FILE_LIST}
  rm -f ${RMAN_TAPE_LIST}
  rm -f ${SQL_FILE}
  
#
#  Run Script
#
  
  fn_last_full_backup

  fn_rman_tape

exit 0

