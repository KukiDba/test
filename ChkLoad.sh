#!/bin/ksh

HOSTNAME=`uname -n`

TopLoadAvg=`/usr/bin/top -b -n 1|grep -i "load average"|tr -s " "`
TopLoadAvg=`echo $TopLoadAvg|cut -d ":" -f5|cut -d "," -f1|cut -d "." -f1`

rm -rf /tmp/ChkLoadEmail.txt

echo $TopLoadAvg
if (( `echo "$TopLoadAvg"| bc`>=$1))
 then
echo '-----------------------------------------------------------------------------------------' >> /tmp/ChkLoadEmail.txt
echo 'Please follow the below procedure when the Load average on SPARKLE (dssp06) is very high.' >> /tmp/ChkLoadEmail.txt
echo ' ' >> /tmp/ChkLoadEmail.txt
echo '1. Login to OEM, validate what is causing the load. ' >> /tmp/ChkLoadEmail.txt
echo '2. Email the top 3 query with session details including OS userid to two Distribution list' >> /tmp/ChkLoadEmail.txt
echo '   a. #MAUSWarehouseETLTeam@hub.wmmercer.com' >> /tmp/ChkLoadEmail.txt
echo '   b. #MAUSBusinessObjectsSupport@hub.wmmercer.com' >> /tmp/ChkLoadEmail.txt
echo '3. After confirmation to clean any session, request for ticket and clean it ' >> /tmp/ChkLoadEmail.txt
echo '4. Follow below procedure for teh same if required.' >> /tmp/ChkLoadEmail.txt
echo '   a. login to the racp2' >> /tmp/ChkLoadEmail.txt
echo "   b. select * from gv$session where sql_id='xxxxxx';" >> /tmp/ChkLoadEmail.txt
echo "   c.  select 'alter system kill session '''|| SID||','||SERIAl#||''' immediate;' from gv$session where sql_id='xxxxxx';" >> /tmp/ChkLoadEmail.txt
echo '   d. run the generated output to kill the sessions causing concurrency waits.' >> /tmp/ChkLoadEmail.txt
echo '5. Inform application team and provide the current status.' >> /tmp/ChkLoadEmail.txt
echo ' ' >> /tmp/ChkLoadEmail.txt

 cat /tmp/ChkLoadEmail.txt | mailx -s "FATAL FATAL FATAL!HostAlert:Load Avg Threshold $1 exceeded on $HOSTNAME. Load Avg at $TopLoadAvg" "monte.g.weiland@marsh.com,#MMCMarshGITO-SupplySharedServices-NAM-DBA@hub.wmmercer.com,Keran.Adikesavan@marsh.com"
fi

