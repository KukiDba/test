
################################
 GARRADIN V12 TRAINING REFRESH
################################


--- Backup source (CGARAUP) database.
Logon as Oracle to aumel21db17vcn1

cd /opt/oracle/bin
. ./CGARAUP1
cd /orabackup01/rman/GARAUP/rman

Remove old backup files, if there are any.

-- The following commands can be used to take a RMAN backup 
rman target/ 

CONFIGURE CONTROLFILE AUTOBACKUP clear;
CONFIGURE DEVICE TYPE DISK clear;
CONFIGURE CONTROLFILE AUTOBACKUP off;
CONFIGURE CONTROLFILE AUTOBACKUP FORMAT FOR DEVICE TYPE DISK TO '/orabackup01/rman/GARAUP/rman/%F';

-- Take backup using 

run {
allocate channel c1 type disk format '/orabackup01/rman/GARAUP/rman/%U' ;
allocate channel c2 type disk format '/orabackup01/rman/GARAUP/rman/%U';
backup database;
backup archivelog from time 'sysdate-1';
}

-- Once backup is complete ftp the backup files to ausyd26db02vcn1: /orabackup/rman/CGARAUP/BkpStartTS_2020_06_27_11_30_01		
	
Backup the spfile and remove/clean-up the target (CGARAUT) database.

-- Backup spfile and shutdown CGARAUT
-- As Oracle

cd /opt/oracle/bin
. ./CGARAUT
cd /opt/oracle/product/19/GAR_uat/dbs
mv initCGARAUT1.ora initCGARAUT1.ora_bak

sqlplus '/ as sysdba' 
create pfile='/opt/oracle/product/19/GAR_uat/dbs/initCGARAUT1.ora' from spfile;

-- Collect the below path information before the database is shutdown. 
alter session set container=GARAUT;
select distinct substr(name, 1, instr(name, '/',-1)) PATH from v$tempfile;
select distinct substr(name, 1, instr(name, '/',-1)) PATH from v$datafile ;
select distinct substr(member,1, instr(member, '/',-1)) PATH from v$logfile;
sho parameter control


srvctl status database -d CGARAUT
srvctl stop database -d CGARAUT


-- Remove related files.

cd /opt/oracle/bin
. ./ASM1
asmcmd -p

cd +DG_DATAOLTP/CGARAUT/CONTROLFILE
rm *CGARAUT*

cd +DG_DATAOLTP/CGARAUT/DATAFILE
rm *

and all other files from the location previously collected. 


-- Remove CONTROLFILE and ONLINELOG folders		

Edit /opt/oracle/product/19/GAR_uat/dbs/initCGARAUT1.ora and change below parameter as follows.

*.cluster_database=false

-- Make sure that below parameters are set.

*.db_file_name_convert='GARAUP','GARAUT'
*.log_file_name_convert='GARAUP','GARAUT'

-- Also check ‘*.compatible=19.0.0’. It should be the same as in the TARGET

. /opt/oracle/bin/CGARAUT
cd /orabackup01/GARAUP/rman 


sqlplus '/ as sysdba' 
shut immediate;
create spfile= '+DG_DATAOLTP/CGARAUT/spfileCGARAUT.ora' from pfile= '/opt/oracle/product/19/GAR_uat/dbs/initCGARAUT1.ora';
start nomount;


rman auxiliary / log=/tmp/restore_GARAUT.log

duplicate database to 'CGARAUT' backup location '/orabackup/rman/CGARAUP/BkpStartTS_2020_06_27_11_30_01';


-- Start database.		
-- Make sure that the DBIDs of the source and cloned databases are different.

(If the database duplication process did not go smoothly and it needed some manual intervention, 
there is a high chance that source and duplicated databases are having the same DBID. 
If the DBIDs are same, registering the cloned database in RMAN catalog will invalidate the 
catalog registration of the source database. This will cause source database backups to fail.)

Compare the DBIDs of  CGARAUT and GARAUP (from where CGARAUT was cloned). Use below query for this. 

SQL> select dbid from v$database;

If DBIDs are same, change the dbid of CGARAUT as follows (this has to be done while the database is in single instance mode):

sqlplus '/ as sysdba'
start mount;
exit;

nid target=sys/xxxx@CGARAUT

sqlplus '/ as sysdba'
start mount;
alter database open resetlogs;
exit;

		
-- Make sure that the temp files are there.

(If database duplication process did not go smoothly and it needed some manual intervention, 
there is a chance that the temporary tablespace is empty. 
In this case, temp files have to be added manually).

sql> select file_name, TABLESPACE_NAME, BYTES, status from dba_temp_files;

		
-- Make the database RAC enabled.

-- Shutdown the database

sqlplus '/ as sysdba'
shut immediate;
exit;

Edit /opt/oracle/product/19/GAR_uat/dbs/initCGARAUT1.ora and change below parameter as follows.

*.cluster_database=true

create spfile='+DG_DATAOLTP/CGARAUT/spfileCGARAUT.ora' from pfile;

-- Revert back to the old parameter file.

cd /opt/oracle/product/19/GAR_uat/dbs
mv initCGARAUT1.ora_bak initCGARAUT1.ora 

		
-- Startup the RAC database.

srvctl status database -d CGARAUT
srvctl start database -d CGARAUT

-- Rename PDB
select NAME, OPEN_MODE, CON_ID from V$PDBS;

alter pluggable database GARAUP open restricted;
connect GARAUP as sysdba;
alter session set container = GARAUP;
alter pluggable database GARAUP rename global_name to GARAUT;

alter pluggable database close immediate;
alter pluggable database open;

srvctl status database -d CGARAUT
srvctl start database -d CGARAUT

		
-- Change database passwords.
Before changing the passwords edit the profile as below

sqlplus / as sysdba
alter session set container=GARAUT;
alter profile MERCER_APP_PROFILE limit password_verify_function null;
alter profile MERCER_USER_PROFILE limit password_verify_function null; 
alter profile MERCER_ADMIN_PROFILE limit password_verify_function null; 
exit;

sqlplus / as sysdba
alter user system 	identified by <default_password>;
alter user sys 		identified by <default_password>;
alter user dbsnmp   	identified by <default_password>;  
alter session set container=GARAUT;
alter user PMS identified by bkcc9_Hmtl3__La3R25 account unlock;
alter user PMSDB identified by seS_IEHu0Mv8O_Lqk4 account unlock;
alter user PDBADMIN  identified by Kh4K2_wC5Vca_cu969 account unlock;
alter user STATS identified by xz9aW_7yAY12ZW_SpI account unlock;
alter user PMS_QUERY identified by o__M__BC2W_zu7j3Yy3 account unlock;

		
-- Re-point the EXPORT directory

As sys user
create or replace directory EXPORT as '/orabackup01/CGARAUT';

alter session set container=GARAUT;

create or replace directory EXP_IMP_DIR as '/orabackup01/export/GARAUT';
		
-- Register the Database in RMAN Catalog
-- Logon as oracle to ausyd26db02vcn1.

. /opt/oracle/bin/CGARAUT
rman target= / catalog=rmanrepo/<password>@gridaup
register database;

		
-- Put the database in NOARCHIVELOG mode

srvctl status database -d CGARAUT
srvctl stop database -d CGARAUT

sqlplus '/ as sysdba'
startup mount;
alter database noarchivelog;
shutdown immediate;
exit;
 
srvctl status database -d CGARAUT
srvctl start database -d CGARAUT

-- Perform Sanity check
 
-- Post Refresh Steps

sqlplus '/ as sysdba'

alter session set container=GARAUT; 

alter profile MERCER_ADMIN_PROFILE limit PASSWORD_VERIFY_FUNCTION  MMC_VERIFY_FUNCTION_ADMIN; 

alter profile MERCER_APP_PROFILE limit PASSWORD_VERIFY_FUNCTION  MMC_VERIFY_FUNCTION_ADMIN; 

alter profile MERCER_USER_PROFILE limit PASSWORD_VERIFY_FUNCTION  MMC_VERIFY_FUNCTION ; 
 
----------------------------------    END   --------------------------------------



