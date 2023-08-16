#!/bin/ksh
#
# Script Name: rman_encrypt.sh
# Script Purpose: Change the encryption status for a database in RMAN
# Usage:  rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>
#
# Parmeters:  DB_ADMIN_DIR      - Admin Directory of the database
#             DBNAME            - Name of the database to backup
#             DEV/MOD/PROD      - Database level to determine which RMAN catalog to use
#             ON/OFF            - Tells the script whether to turn encryption on or turn it off
#
# 04/30/2010 Nick Pranger   Created
#

#
# FUNCTIONS
#

#
# Generate the RMAN command file for turning on encryption for a database in the catalog
#

fn_gen_cmd_on()
{
  echo "connect target;" > ${CMDFILE}
  echo "connect catalog ${RMANID}/${RMANPWD}@${RMANSID};" >> ${CMDFILE}
  echo "configure encryption for database on;" >> ${CMDFILE}
  echo "configure encryption algorithm 'AES256';" >> ${CMDFILE}
  echo "exit;" >> ${CMDFILE}
}

#
# Generate the RMAN command file for turning off encryption for a database in the catalog
#

fn_gen_cmd_off()
{
  echo "connect target;" > ${CMDFILE}
  echo "connect catalog ${RMANID}/${RMANPWD}@${RMANSID};" >> ${CMDFILE}
  echo "configure encryption for database off;" >> ${CMDFILE}
  echo "exit;" >> ${CMDFILE}
}

#
# Run the rman command to modify the encryption for the database
#

fn_modify_enc()
{
  echo " Initiated database backup encryption change!" | ${LOG_CMD_MAIN}
  ${RMAN} cmdfile ${CMDFILE} log ${CURR_LOG}
  VALUE_RET=$?

  cat ${CURR_LOG} | ${LOG_CMD_MAIN}

  if [ ${VALUE_RET} = 0 ] ; then
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " RMan encryption change SUCCESSFULL for ${DBNAME} on ${TS} - New setting is ${ON_OFF}!" | ${LOG_CMD_MAIN}
    echo " " | ${LOG_CMD_MAIN}
    backup_success='Y'
  else
    export TS=`date '+%d-%b-%Y %H:%M'`
    echo " " | ${LOG_CMD_MAIN}
    echo " RMan encryption change FAILED for ${DBNAME} on ${TS}!" | ${LOG_CMD_MAIN}
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
  echo "rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>."
  echo "Aborting!"
  exit 1
fi

if [ -z $2 ]; then 
  echo "DB Name was not passed correctly."
  echo "Correct format for calling is : "
  echo "rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>."
  echo "Aborting!"
  exit 1
fi

if [ -z $3 ]; then 
  echo "DB Level (DEV/MOD/PROD) was not passed correctly."
  echo "Correct format for calling is : "
  echo "rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>."
  echo "Aborting!"
  exit 1
else
  case $3 in
     DEV) ;;
     MOD) ;;
    PROD) ;;
       *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
          echo "Correct format for calling is : "
          echo "rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>."
          echo "Aborting!"
          exit 1;;
  esac
fi

if [ -z $4 ]; then 
  echo "Encryption Change Type (ON/OFF) was not passed correctly."
  echo "Correct format for calling is : "
  echo "rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>."
  echo "Aborting!"
  exit 1
else
  case $4 in
     ON) ;;
     OFF) ;;
       *) echo "DB Level (DEV/MOD/PROD) was not passed correctly."
          echo "Correct format for calling is : "
          echo "rman_encrypt.sh <DB_ADMIN_DIR> <DBNAME> <DEV/MOD/PROD> <ON/OFF>."
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
export ON_OFF=$4
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
SCRIPT_NAME=rman_encrypt

DB_RMAN_DIR=${DBADMIN}/rman
if [ ! -d ${DB_RMAN_DIR} ]; then
  mkdir -p ${DB_RMAN_DIR}
  if [ $? -ne 0 ]; then
    echo " Error creating log directory ${DB_RMAN_DIR}. Aborting!/n"
    exit 1
  fi
fi

LOG_DIR=${DB_RMAN_DIR}
CMDFILE=${DB_RMAN_DIR}/encrypt_${DBNAME}.rmc
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

echo "Starting RMAN Encryption change of ${DBNAME} at ${TS} - New setting is ${ON_OFF}." | ${LOG_CMD_MAIN}
echo " " | ${LOG_CMD_MAIN}

if [ ${ON_OFF} = 'ON' ]; then
  fn_gen_cmd_on
elif [ ${ON_OFF} = 'OFF' ]; then
  fn_gen_cmd_off
fi

fn_modify_enc

export TS=`date '+%d-%b-%Y %H:%M'`

echo " " | ${LOG_CMD_MAIN}
echo "Ending RMAN Encryption change of ${DBNAME} at ${TS} - New setting is ${ON_OFF}." | ${LOG_CMD_MAIN}

