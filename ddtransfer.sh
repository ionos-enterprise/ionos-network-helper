#!/bin/bash

# Georg Schieche-Dirik
# Script to transfer raw images using the dd command over ssh
# via network.

# This script is work in progress. And as in general: use at your own risk!
# License GPL v. 3

if [ $# -le "1" ] ; then
cat <<-ENDOFMESSAGE
    Usage: $0 -l|--local_device 'source_device' -r|--remote_device 'target_device' -H|--TargetHost 'target_host'
    (--no_compression (per default compression is active)
    (-p|--ssh_port 'ssh_port' (default is '22')) 
    (-m|--max_connections (max transmissions in parallel, default is 8)) 
    (-S|--restart 'formerly written report file' (any other given option will be overwritten))

    A running ssh-agent is necessary.

    Tested with ext4, ntfs, xfs, btrfs.
    It is recommended not to start any other dd execution on the local or target host while this programm is running.

    For sudo users like Ubuntu, do:
    1) 'sudo su -'
    2) 'eval \`ssh-agent -s\`'
    3) 'ssh-add /home/user/.ssh/id_rsa'
    Now you can start the dd-transfer script.

    Example:

    $0 -l /dev/vdd -r /dev/vdd -H 46.16.76.151 
    $0 --local_device /dev/vdd --remote_device /dev/vdd --TargetHost 46.16.76.151 

    This transfers the contents from the local storage volume /dev/vdd to the remote volume /dev/vdd on host 46.16.76.151.
    Partitions like /dev/vdd1 are also usable.
ENDOFMESSAGE
exit
fi

Compression='-C'
MaxSSHConnections=100
SSHPort=22 
ProcessNumber=8 
AvailableSpaceMin=1055162163 # 1G
MinOperatingSystemSpace=${AvailableSpaceMin}
SectorSize=512 
JobID=$$
UsedOptions=$@
Cores=$(grep -c processor /proc/cpuinfo) ; if [ ${Cores} -eq 1 ] ; then Cores=2 ; fi

while test $# -gt 0 ; do
    case "$1" in
        -h|--help)
            $0 ;; 
        -S|--restart) shift; 
            GivenReportFile=$1
            shift ;;
        -l|--local_device) shift; 
            SourceDevice=$1
            shift ;;
        -r|--remote_device) shift;
            TargetDevice=$1
            shift ;;
        -n|--no_compression) 
            Compression=''
            shift ;;
        -m|--max_connections) shift;
            ProcessNumber=$1
            shift ;;
        -p|--ssh_port) shift;
            SSHPort=$1
            shift ;;
        -H|--TargetHost) shift;
            TargetHost=$1
            shift ;;
        *)  echo "ERROR: Missing correct option, try $0 to get help"
            exit 2 ;;
    esac
done


if ! ssh-add -l 2>&1 ; then
    echo "A running SSH agent is necessary!"
    exit 2
fi

if ! /usr/bin/which buffer ; then
    echo "Install buffer which is needed for the transfer over SSH!"
    exit 2
fi

if [ ! ${GivenReportFile} ] ; then

    JobTime=$(date +%s)
    JobTimeFile=$(date --date="@$JobTime" +%Y-%m-%d-%H-%M-%S)
    Report=$(pwd)/report_ddt_${JobTime}_${JobID}.log
    if [[ "${TargetHost}" =~ "," ]] ; then
	TargetHostS=( ${TargetHost//,/ } )
	TargetHost=${TargetHost%% *}
        SSH_command="ssh $Compression -p $SSHPort root@${TargetHostS[0]}"
    else
        SSH_command="ssh $Compression -p $SSHPort root@${TargetHost}"
    fi

    (
        echo "Invoked command is"
        echo "$0 ${UsedOptions}"
        echo "JobID=${JobID}"
        echo "JobTime=${JobTime}"
        echo "SourceDevice=${SourceDevice}"
        echo "TargetDevice=${TargetDevice}"
        echo "SSHPort=${SSHPort}"
        echo "TargetHost=${TargetHost}"
        echo "TargetHostS=${TargetHostS}"
        echo "Compression=${Compression}"
        echo "ProcessNumber=${ProcessNumber}"
        echo "SSH_command=\""${SSH_command}"\""
        echo "AvailableSpaceMin=${AvailableSpaceMin}"
        echo
    ) | tee ${Report}

else

    Report=${GivenReportFile}
    for FormerJobVariable in $(grep -P '^[A-Za-z_]*=' ${Report}) ; do
        eval $(grep -o -P -m 1 "^${FormerJobVariable}.*" ${Report})
    done

    JobTimeFile=$(date --date="@$JobTime" +%Y-%m-%d-%H-%M-%S)

    if $SSH_command "ps cax | grep 'dd count=' 2> /dev/null" ; then (
        echo
        echo "ERROR: dd processes are still running on remote host!"
        echo "They might be related to a former execution of $0."
        echo "Please wait until they are finished or stop them."
        echo ) | tee -a ${Report}
        exit 2
    fi

fi

if ! fdisk -l ${SourceDevice} 2>&1 > /dev/null ; then
    echo
    echo "ERROR: Read and write access to device ${SourceDevice} is crucial!"
    exit 2
elif ! ${SSH_command} "fdisk -l ${TargetDevice} 2>&1 > /dev/null" ; then
    echo
    echo "ERROR: Read and write access to remote device ${TargetDevice} is crucial!"
    exit 2
fi

Blocks=$(cat /sys/block/${SourceDevice##*/}/device/block/${SourceDevice##*/}/size 2>/dev/null)
if [[ "${Blocks}" == "" ]] ; then
    SourceDeviceRaw=${SourceDevice##*/} ; SourceDeviceRaw=${SourceDeviceRaw//[0-9]/}
    SourceDeviceNumber=${SourceDevice##*/}; SourceDeviceNumber=${SourceDeviceNumber//[a-z]/}
    Blocks=$(cat /sys/block/${SourceDeviceRaw}/device/block/${SourceDeviceRaw}/${SourceDeviceRaw}${SourceDeviceNumber}/size 2>/dev/null)
fi
if [[ "${Blocks}" == "" ]] ; then
    LVM=$(ls -l ${SourceDevice} | grep -P -o 'dm-.*')
    Blocks=$(cat /sys/block/${LVM}/size 2>/dev/null)
fi
if [[ "${Blocks}" == "" ]] ; then
    echo "Number of device blocks for ${SourcdDevice} could not be found! Exiting..."
    exit 2
fi

StartBlock=1
Run=0
SectorPortion=$(( ${Blocks} / $(( ${ProcessNumber} * ${ProcessNumber} * 8 )) ))

while [[ ${SectorPortion} -gt $((${AvailableSpaceMin} / ${ProcessNumber})) ]] ; do 
    Run=$((${Run}+1))
    SectorPortion=$(( ${Blocks} / $((${ProcessNumber} * ${Run})) ))
done

BlockCount=${Cores}
Chunk=$((${SectorPortion} * ${SectorSize} / ${Cores}))
FileSize=$((${SectorPortion} * ${SectorSize}))
LastRun=$(( ${Blocks} / $SectorPortion ))
Iterations=( $(seq ${LastRun}) )

function BasicTransfer() {

    IterationsRun=( "$@" )

    for Iteration in  ${IterationsRun[@]} ; do

	while [[ $(ps ax | grep -c "count=${BlockCount} bs=${Chunk}") -gt $(($ProcessNumber+1)) ]] ; do sleep 2 ; done
    
    	if [[ "${TargetHostS}" != "" ]] ; then
    	    TargetHost=$(for Host in ${TargetHostS[*]} ; do echo ${Host}; done |
    		while read ; do
    		    echo -n "$REPLY "
    		    ps ax | grep -c $REPLY
    		done | sort -r -n -k2 | tail -n 1 | cut -d ' ' -f1)
    	    SSH_command="ssh $Compression -p $SSHPort root@${TargetHost}"
    	fi
    
        (   Step=${Iteration}
            Skip=$(($((${Iteration}-1)) * ${BlockCount}))

    	    dd count=${BlockCount} bs=${Chunk} if=${SourceDevice} skip=${Skip} iflag=fullblock status=none | \
    	        tee >(sha256sum | while read ; do echo "Step ${Step} local  is ${REPLY%  -}" >> ${Report} ; done) | \
                buffer -S 10m 2> /dev/null | \
        	$SSH_command "dd count=${BlockCount} bs=${Chunk} of=${TargetDevice} seek=${Skip} iflag=fullblock status=none"
    
    	    $SSH_command "dd count=${BlockCount} bs=${Chunk} if=${TargetDevice} skip=${Skip} iflag=fullblock status=none | sha256sum " | \
    	        while read ; do echo "Step ${Step} remote is ${REPLY%  -}" >> ${Report} ; done
    
    	    grep -P "Step ${Step} local" ${Report} | tail -n 1  
    	    grep -P "Step ${Step} remote" ${Report} | tail -n 1  
    	) &
    
    	echo "Step $Iteration of ${IterationsRun[-1]} in progress."
    	sleep 1
    done
    
    while [[ $(ps ax | grep -c "count=${BlockCount} bs=${Chunk}") -gt 2 ]] ; do sleep 2 ; done
}

function CheckSumControll {
    FailedTransfers=()
    SuccessTransfers=()
    echo "Comparing data checksum results..."
    
    for Iteration in ${Iterations[@]} ; do
        Local=$(grep -P "Step ${Iteration} local  is " ${Report} | tail -n 1 | cut -d ' ' -f6)
        Remote=$(grep -P "Step ${Iteration} remote is " ${Report} | tail -n 1 | cut -d ' ' -f5)
        
        if [[ "${Local}" != "${Remote}" ]] || [[ "${Remote}" == "" ]] ; then
            echo "WARNING: Checksum for local and remote step ${Iteration} is not identical!" | tee -a ${Report}
            echo "Attempt to fix will be initiated."
    
            FailedTransfers+=( ${Iteration} )
	else
            SuccessTransfers+=( ${Iteration} )
        fi
    done

    if [[ "${FailedTransfers}" != "" ]] ; then

        BasicTransfer "${FailedTransfers[@]}"
            
        while [[ $(ps ax | grep -c "count=${BlockCount} bs=${Chunk}") -gt 1 ]] ; do sleep 2 ; done

        echo "Retransmission of ${#FailedTransfers[@]} failed steps done." | tee -a ${Report}
        echo "Check ${Report} for status."

    else
        echo "Job finished, ${#FailedTransfers[@]} errors reported!" | tee -a ${Report}
    fi
}

export -f BasicTransfer

if [ ! ${GivenReportFile} ] ; then
    echo Start from image part ${StartBlock} to part ${LastRun} with ${Blocks} blocks at $JobTimeFile
    BasicTransfer "${Iterations[@]}"
else
    FollowUp=()
    echo "Process ${GivenReportFile}"
    AlreadyDone=( $(grep -P "Step [0-9]+ remote is " ${GivenReportFile} | cut -d ' ' -f 2) )

    for Step in ${Iterations[@]} ; do
        if [[ ! " ${AlreadyDone[@]} " =~ " ${Step} " ]] ; then
	    FollowUp+=( ${Step} )
	fi
    done
    
    RemainStart=$((${#AlreadyDone[*]}+1))
    echo "Start from image part ${Iterations[${RemainStart}]} to part ${LastRun} with ${Blocks} blocks at $JobTimeFile"

    BasicTransfer "${FollowUp[@]}" 
fi

CheckSumControll 


