#!/bin/ksh

####################################################
#%1 is threshold for total non idle cpu.  Once crossed, this script will send email

######################### start of code  #########################
HOSTNAME=`uname -n`

#do a top cmd, remove extra spaces so cols can be pulled out correctly, strip out %'s
rm -rf /tmp/ChkCpu.txt
rm -rf /tmp/ChkCpuEmail.txt
/usr/bin/top -b -d1 -n3>/tmp/ChkCpu.txt

vTopCpuLine=`cat /tmp/ChkCpu.txt|grep -i "cpu(s)"|tail -1|tr -s " "|sed s/%//g|sed s/")"//g|sed s/"("//g`

echo '-----------------------------------------------------------------------------------------' >> /tmp/ChkCpuEmail.txt
echo 'Please follow the below procedure when the Load average on SPARKLE (dssp06) is very high.' >> /tmp/ChkCpuEmail.txt
echo ' ' >> /tmp/ChkCpuEmail.txt
echo '1. Login to OEM, validate what is causing the load. ' >> /tmp/ChkCpuEmail.txt
echo '2. Email the top 3 query with session details including OS userid to two Distribution list' >> /tmp/ChkCpuEmail.txt
echo '   a. #MAUSWarehouseETLTeam@hub.wmmercer.com' >> /tmp/ChkCpuEmail.txt
echo '   b. #MAUSBusinessObjectsSupport@hub.wmmercer.com' >> /tmp/ChkCpuEmail.txt
echo '3. After confirmation to clean any session, request for ticket and clean it ' >> /tmp/ChkCpuEmail.txt
echo '4. Follow below procedure for teh same if required. ' >> /tmp/ChkCpuEmail.txt
echo '   a. login to the racp2' >> /tmp/ChkCpuEmail.txt
echo "   b. select * from gv$session where sql_id='xxxxxx';" >> /tmp/ChkCpuEmail.txt
echo "   c.  select 'alter system kill session '''|| SID||','||SERIAl#||''' immediate;' from gv$session where sql_id='xxxxxx';" >> /tmp/ChkCpuEmail.txt
echo '   d. run the generated output to kill the sessions causing concurrency waits. ' >> /tmp/ChkCpuEmail.txt
echo '5. Inform application team and provide the current status. ' >> /tmp/ChkCpuEmail.txt
echo ' ' >> /tmp/ChkCpuEmail.txt

#grab values from top and put in vars
CpuUserPercent=`echo $vTopCpuLine|cut -f2 -d " "`
CpuKernelPercent=`echo $vTopCpuLine|cut -f4 -d " "`
CpuNiPercent=`echo $vTopCpuLine|cut -f6 -d " "`
CpuIdlePercent=`echo $vTopCpuLine|cut -f8 -d " "`
CpuIOWaitPercent=`echo $vTopCpuLine|cut -f10 -d " "`
CpuHiPercent=`echo $vTopCpuLine|cut -f12 -d " "`
CpuSwapPercent=`echo $vTopCpuLine|cut -f14 -d " "`

CpuTotal=`echo "$CpuUserPercent+$CpuKernelPercent+$CpuNiPercent+$CpuIdlePercent+$CpuIOWaitPercent+$CpuHiPercent+$CpuSwapPercent" |bc -l`
CpuNonIdleTot=`echo "$CpuUserPercent+$CpuKernelPercent+$CpuNiPercent+$CpuIOWaitPercent+$CpuHiPercent+$CpuSwapPercent"|bc -l`

###############################################################
CpuNonIdleTot=`echo $CpuNonIdleTot| cut -d "." -f1`

echo $vTopCpuLine
echo "Total:$CpuTotal"
echo "NonIdle:$CpuNonIdleTot"

### if cpu% higher than threshold, send mail
if (( `echo "$CpuNonIdleTot"| bc`>=$1))
 then
 cat /tmp/ChkCpuEmail.txt | mailx -s "HostAlert:CPU Threshold $1% exceeded on $HOSTNAME. CPU at $CpuNonIdleTot%" "monte.g.weiland@marsh.com,#MMCMarshGITO-SupplySharedServices-NAM-DBA@hub.wmmercer.com,Keran.Adikesavan@marsh.com"
 #echo $vTopCpuLine | mailx -s "HostAlert:CPU Threshold $1% exceeded on $HOSTNAME. CPU at $CpuNonIdleTot%" "monte.g.weiland@marsh.com,#MMCMarshGITO-SupplySharedServices-NAM-DBA@hub.wmmercer.com"
fi

