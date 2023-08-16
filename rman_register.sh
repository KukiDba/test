#!/bin/ksh
#
# Script Name: rman_register.sh
# Script Purpose: Dynamically run an rman database backup for a database on this machine
# Usage:  rman_register.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>
#
# Parmeters:  DB_ADMIN_DIR      - Admin Directory of the database
#             DBNAME            - Name of the database to backup
#             DEV/MOD/PROD      - Database level to determine which RMAN catalog to use
#
# 06/12/2007 Nick Pranger   Created
# 10/17/2007 Nick Pranger   Changed the ADMIN directory parameter to be the database admin directory instead of the machine admin directory
# 10/30/2007 Nick Pranger   Made changes to reflect proper times when outputting them to the log files.
# 08/20/2008 Nick Pranger   Made changes to use the .server_environ file instead of the .rman_environ file
# 02/10/2009 Nick Pranger   Version 8.0 release started on 2/10/2009
#

#
# FUNCTIONS
#

#
# Generate the RMAN command file for registering a database in the catalog
#

fn_gen_cmd()
{
  echo "connect target;" > ${CMDFILE}
  echo "connect catalog ${RMANID}/${RMANPWD}@${RMANSID};" >> ${CMDFILE}
  echo "register database;" >> ${CMDFILE}
  echo "exit;" >> ${CMDFILE}
}

#
# Run the rman command to register the database
#

fn_register_db()
{
  echo " Initiated database registration!" | ${LOG_CMD_MAIN}
  ${RMAN} cmdfile ${CMDFILE} log ${CURR_LOG}
  VALUE_RET=$?

  cat ${CURR_LOG} | ${LOG_CMD_MAIN}

  if [ ${VALUE_RET} = 0 ] ; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " RMan Registration SUCCESSFULL for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    backup_success='Y'
  else
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " RMan Registration FAILED for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    backup_success='N'
  fi
}

#
#  MAIN CODE
#

#
# Check input variables
#

if [ -z $1 ]; then 
  echo "Database admin was not passed correctly."
  echo "Correct format for calling is : "
  echo "rman_register.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
  echo "Aborting!"
  exit 1
fi

if [ -z $2 ]; then 
  echo "DB Name was not passed correctly."
  echo "Correct format for calling is : "
  echo "rman_register.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
  echo "Aborting!"
  exit 1
fi

if [ -z $3 ]; then 
  echo "DB Level (DEV/MOD/PROD) was not passed correctly."
  echo "Correct format for calling is : "
  echo "rman_register.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
  echo "Aborting!"
  exit 1
else
  case $3 in
     DEV) ;;
     MOD) ;;
    PROD) ;;
       *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
          echo "Correct format for calling is : "
          echo "rman_register.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD>."
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
export ORACLE_OWNER=oracle
export ORACLE_GROUP=dba

#
# The below 3 environment sourcing lines are done in this manner on purpose
#   the .{DBNAME}_env file is sourced to get the proper ORACLE_HOME information for the database
#   the .server_environ file is then sourced to get the default values for variables and general setups
#   the .{DBNAME}_env file is then sourced a second time to do overrides of the defaults if needed
#
  . ${DBADMIN}/.${DBNAME}_env
  . `dirname $0`/../.server_environ
  . ${DBADMIN}/.${DBNAME}_env

export TS=`date '+%d-%b-%Y %H:%M'`
SCRIPT=$0
SCRIPT_NAME=rman_register

DB_RMAN_DIR=${DBADMIN}/rman
if [ ! -d ${DB_RMAN_DIR} ]; then
  mkdir -p ${DB_RMAN_DIR}
  if [ $? -ne 0 ]; then
    echo " Error creating log directory ${DB_RMAN_DIR}. Aborting!/n"
    exit 1
  fi
fi

LOG_DIR=${DB_RMAN_DIR}
CMDFILE=${DB_RMAN_DIR}/register_${DBNAME}.rmc
MAIN_LOG=${LOG_DIR}/${SCRIPT_NAME}_${DBNAME}_`date +%Y%m%d%H%M`.log
CURR_LOG=${LOG_DIR}/${SCRIPT_NAME}.log
LOG_CMD_MAIN="tee -a ${MAIN_LOG}"

${RM} -f ${CMDFILE}
${RM} -f ${CURR_LOG}
touch ${CURR_LOG}
cat /dev/null > ${CURR_LOG}

#
#  Run Script
#

export TS=`date '+%d-%b-%Y %H:%M'`

echo "Starting registration of ${DBNAME} at ${TS}." | ${LOG_CMD_MAIN}
echo " " | ${LOG_CMD_MAIN}

fn_gen_cmd
fn_register_db

export TS=`date '+%d-%b-%Y %H:%M'`

echo " " | ${LOG_CMD_MAIN}
echo "Ending registration of ${DBNAME} at ${TS}." | ${LOG_CMD_MAIN}

