#!/bin/bash

# Georg Schieche-Dirik
# Script to transfer raw images using the dd and rsync commands
# via network.

# This script is work in progress. And as in general: use at your own risk!
# License GPL v. 3

if [ $# -le "1" ] ; then
cat <<-ENDOFMESSAGE
    Usage: $0 -l|--local_device 'source_device' -r|--remote_device 'target_device' -H|--TargetHost 'target_host'
    (-R|--remote_transfer_dir 'remote_transfer_directory' (default is '/homedir'))
    (-T|--local_transfer_dir 'transfer_directory' (default is '/homedir'))
    (-c|--compress_level 'level of compression for rsync' (default is '9', the highest), s3cmd also has compression with level 6 but can not be changed)
    (-p|--ssh_port 'ssh_port' (default is '22')) (-k|--keep_logs keep log files in transfer directory)
    (-t|--RsyncTimeout 'rsync_timeout' (default is '60' in seconds')) 
    (-m|--max-connections (default is 8)) 
    (-s|--s3|--S3 (use s3 storage to transfer the image files)) 
    (-p|--s3|--S3 (use s3 storage to transfer the image files)) 
    (-S|--restart 'formerly written report file' (any other given option will be overwritten))
    (-s|--s3|--S3 (use s3 storage to transfer the image files))
    (-P|--GPGPass 'passphrase' (passphrase to encrypt the image files, default is taken from ~/.s3.cfg)) 
    For rsync a running ssh-agent is necessary.
    Tested with ext4, ntfs, xfs, btrfs.
    It is recommended not to start any other dd execution on the local or target host while this programm is running.

    For sudo users like Ubuntu, do:
    1) 'sudo su -'
    2) 'eval \`ssh-agent -s\`'
    3) 'ssh-add /home/user/.ssh/id_rsa'
    Now you can start the dd-transfer script.

    Example:

    $0 -l /dev/vdd -r /dev/vdd -H 46.16.76.151 -R /mnt -k
    $0 --local_device /dev/vdd --remote_device /dev/vdd --TargetHost 46.16.76.151 --remote_transfer_dir /mnt --keep_logs

    This transfers the contents from the local storage volume /dev/vdd to the remote volume /dev/vdd on host 46.16.76.151.
    There in the directory /mnt the temporary image files are stored before they are send to the device. The log files are kept.
ENDOFMESSAGE
exit
fi

MaxSSHConnections=100
KeepLogs=no
SSHPort=22 
CompressLevel=9
ProcessNumber=8 # Number of transfer processes in parallel, change only if you know what you are doing!
TransferDir=${HOME}
RemoteTransferDir=${HOME}
AvailableSpaceMin=5275810816 # 5G
MinOperatingSystemSpace=$((${AvailableSpaceMin} / 5))
SectorSize=512 
RsyncTimeout=60
JobID=$$
UsedOptions=$@
GPGPass=$(grep gpg_passphrase ~/.s3cfg | cut -d ' ' -f3)
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
        -c|--compress_level) shift;
            CompressLevel=$1
            shift ;;
        -m|--max-connections) shift;
            ProcessNumber=$1
            shift ;;
        -p|--ssh_port) shift;
            SSHPort=$1
            shift ;;
        -T|--local_transfer_dir) shift;
            TransferDir=$1
            shift ;;
        -R|--remote_transfer_dir) shift;
            RemoteTransferDir=$1
            shift ;;
        -H|--TargetHost) shift;
            TargetHost=$1
            shift ;;
        -t|--RsyncTimeout) shift;
            RsyncTimeout=$1
            shift ;;
        -P|--GPGPass) shift;
            GPGPass=$1
            shift ;;
        -s|--s3|--S3) 
            UseS3=yes
            shift ;;
        -k|--keep_logs) 
            KeepLogs=yes
            shift ;;
        *)  echo "ERROR: Missing correct option, try $0 to get help"
            exit 2 ;;
    esac
done


if ! ssh-add -l 2>&1 ; then
    echo "A running SSH agent is necessary!"
    exit 2
fi

if [ ! ${GivenReportFile} ] ; then

    JobTime=$(date +%s)
    JobTimeFile=$(date --date="@$JobTime" +%Y-%m-%d-%H-%M-%S)
    Report=$(pwd)/report_ddt_${JobTime}${JobID}.log
    LogDir=${TransferDir}/DiskTransfer_${JobTime}_${JobID} 
    RemoteLogDir=${RemoteTransferDir}/DiskTransfer_${JobTime}_${JobID} 
    SSH_command="ssh -p $SSHPort root@${TargetHost}"
    SCP_command="scp -P $SSHPort"
    TransferBucket=ddtransfer-${JobTime}-${JobID}

    (
        echo "Invoked command is"
        echo "$0 ${UsedOptions}"
        echo "JobID=${JobID}"
        echo "JobTime=${JobTime}"
        echo "SourceDevice=${SourceDevice}"
        echo "TargetDevice=${TargetDevice}"
        echo "SSHPort=${SSHPort}"
        echo "TransferDir=${TransferDir}"
        echo "RemoteTransferDir=${RemoteTransferDir}"
        echo "TargetHost=${TargetHost}"
        echo "RsyncTimeout=${RsyncTimeout}"
        echo "KeepLogs=${KeepLogs}"
        echo "LogDir=${LogDir}"
        echo "CompressLevel=${CompressLevel}"
        echo "RemoteLogDir=${RemoteLogDir}"
        echo "ProcessNumber=${ProcessNumber}"
        echo "SSH_command=\""${SSH_command}"\""
        echo "SCP_command=\""${SCP_command}"\""
        echo "AvailableSpaceMin=${AvailableSpaceMin}"
        if [[ "${UseS3}" == "yes" ]] ; then
            echo "UseS3=${UseS3}"
            echo "TransferBucket=${TransferBucket}"
            echo "GPGPass=${GPGPass}"
        fi
        echo
    ) | tee ${Report}

else

    Report=${GivenReportFile}
    for FormerJobVariable in $(grep -P '^[A-Za-z_]*=' ${Report}) ; do
        eval $(grep -o -P -m 1 "^${FormerJobVariable}.*" ${Report})
    done

    JobTimeFile=$(date --date="@$JobTime" +%Y-%m-%d-%H-%M-%S)

    if [[ $(ps cax | grep rsync 2> /dev/null) ]] ; then (
        echo
        echo "ERROR: rsync processes are still running!"
        echo "They might be related to a former execution of $0."
        echo "Please wait until they are finished or stop them."
        echo ) | tee -a ${Report}
        exit 2
    elif $SSH_command "ps cax | grep 'dd count=' 2> /dev/null" ; then (
        echo
        echo "ERROR: dd processes are still running on remote host!"
        echo "They might be related to a former execution of $0."
        echo "Please wait until they are finished or stop them."
        echo ) | tee -a ${Report}
        exit 2
    fi

    (   echo "Removing partly processed local files of former command run:"
        rm -v $LogDir/*img
        for i in $(ls $LogDir/*ongoing) ; do mv -v ${i} ${i%.ongoing} ; done
        echo

        echo "Removing partly processed remote files of former command run:"
        echo
        $SSH_command "find ${RemoteLogDir} -name \"*.ToDev\" | grep -v done | while read ; do mv -v \${REPLY} \${REPLY%.ToDev} ; done"
        echo
        $SSH_command "find ${RemoteLogDir} -name \"*.transfer.*\" | grep -v done | while read ; do rm -v \${REPLY} ; done"
        echo

    ) | tee -a ${Report}

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

if [[ "$UseS3" == "yes" ]] ; then
    if ! s3cmd ls 2>&1 > /dev/null ; then
        echo "Install and configure s3cmd first!" 
        exit 2
    fi
    if ! s3cmd mb s3://${TransferBucket} ; then
        echo "Creating transfer bucket failed, install and configure s3cmd first!" 
        exit 2
    fi
    if ! ${SSH_command} "s3cmd ls s3://${TransferBucket}" ; then
        echo "Remote execution of bucket reading failed. Install and configure s3cmd on target host first!" 
        exit 2
    fi
    if [[ "$GPGPass" == "" ]] ; then
        echo "GPG passphrase is missing! Put one into ~/.s3.cfg or give it as commandline option." 
        exit 2
    fi
elif ! which rsync 2>&1 > /dev/null ; then
    echo "The programm 'rsync' is missing, please install it."
    exit 2
else 
    Rsync_command='rsync -e "'"ssh -p ${SSHPort}"'" --timeout='${RsyncTimeout}' --compress --compress-level='${CompressLevel}''
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
Skip=0
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
Iterations=( $(seq -w ${LastRun}) )

GetWorkSpace="df -P -B1 $TransferDir | grep /dev/ | tr -s ' ' | cut -d ' ' -f4"
if [[ $(eval $GetWorkSpace) -lt $AvailableSpaceMin ]] ; then
    echo "Fatal: Not enough diskspace locally, exiting!"
    exit 2
fi

GetRemoteWorkSpace="df -P -B1 $RemoteTransferDir | grep /dev/ | tr -s ' ' | cut -d ' ' -f4"
if [[ $($SSH_command "eval $GetRemoteWorkSpace") -lt $AvailableSpaceMin ]] ; then
    echo "Fatal: Not enough diskspace on target host, exiting!"
    exit 2
fi

mkdir -p ${LogDir}
$SSH_command "[ -e ${RemoteLogDir} ] || mkdir ${RemoteLogDir}"

if [ ! ${GivenReportFile} ] ; then
    for i in $(echo ${Iterations[*]}) ; do 
        touch ${LogDir}/${JobTimeFile}_${i}.run
    done
elif [ ${GivenReportFile} ] ; then
    RemoteFilesInProcess=( $($SSH_command "ls ${RemoteLogDir}/*_${JobTimeFile}.* | grep -P -o 'DeviceCopy_[0-9]*_' | grep -P -o '[0-9]*'") )
    LocalFilesToProcess=( $(ls ${LogDir}/${JobTimeFile}*.run 2>&1 | grep -P -o '[0-9]{4}.run' | grep -P -o '[0-9]*') )
    for MissingDoneOrRun in $(echo ${Iterations[@]} ${LocalFilesToProcess[@]} ${RemoteFilesInProcess[@]} | tr ' ' '\n' | sort | uniq -u) ; do
        touch ${LogDir}/${JobTimeFile}_${MissingDoneOrRun}.run
    done
fi

function dd_command() {
    Direction=$1
    Device=$2
    File=$3

    if [ "$Direction" == "From" ] ; then 
        Input=$Device
        Output=$File
    elif [ "$Direction" == "To" ] ; then 
        Input=$File
        Output=$Device
    fi

    Param=( $(echo ${File//_/ }) )
    Step=${Param[3]}
    Chunk=${Param[4]}
    Count=${Param[5]}
    Skip=${Param[6]}
    Groth=0

    if [[ "${Output}" =~ ".img" ]] ; then

        echo "Copying into ${File}"

        if [[ "$UseS3" == "yes" ]] ; then

            echo "dd count=${Count} if=${Input} bs=${Chunk} skip=$Skip | tee >(gpg -c --batch --passphrase ${GPGPass} -o ${Output}) | sha256sum"
            CheckSum=$(dd count=${Count} if=${Input} bs=${Chunk} skip=$Skip | tee >(gpg -c --batch --passphrase ${GPGPass} -o ${Output}) | sha256sum)
            sleep 2

        else

            echo "dd count=${Count} if=${Input} bs=${Chunk} skip=$Skip | tee ${Output} | sha256sum"
            CheckSum=$(dd count=${Count} if=${Input} bs=${Chunk} skip=$Skip | tee ${Output} | sha256sum)

            while [ ${Groth} -lt ${FileSize} ] ; do
                sleep 2
                Groth=$(ls -l ${File} | cut -f5 -d ' ')
            done

        fi

        echo "Checksum step ${Step} local is ${CheckSum% -}" | tee -a ${Report}
        mv ${TransferFile}.img ${TransferFile}.img.transfer

    elif [[ "${Output}" =~ "/dev/" ]] ; then

        echo "Writing to device ${File}"

        if [[ "$UseS3" == "yes" ]] ; then
            echo "$SSH_command \"gpg -d --batch --passphrase ${GPGPass} -o - ${Input} | dd iflag=fullblock count=${Count} of=${Output} bs=${Chunk} seek=$Skip\""
            $SSH_command "gpg -d --batch --passphrase ${GPGPass} -o - ${Input} | dd iflag=fullblock count=${Count} of=${Output} bs=${Chunk} seek=$Skip 2>&1" 
            sleep 2
            Done=${Input%.img.transfer.s3.ToDev}.done
        else
            echo "$SSH_command \"dd count=${Count} if=${Input} of=${Output} bs=${Chunk} seek=${Skip}\""
            $SSH_command "dd count=${Count} if=${Input} of=${Output} bs=${Chunk} seek=${Skip} 2>&1" 
            sleep 2
            Done=${Input%.img.transfer.ToDev}.done
        fi

        echo "and"
        echo "$SSH_command \"dd count=${Count} if=${Output} bs=${Chunk} skip=${Skip} | sha256sum\""
        CheckSum=$($SSH_command "dd count=${Count} if=${Output} bs=${Chunk} skip=${Skip} | sha256sum") 
        sleep 2
        echo

        echo "Checksum step ${Step} remote is ${CheckSum% -}" | tee -a ${Report}

        StepCount=0
        while ! $SSH_command "mv -v ${Input} ${Done} ; echo 0 > ${Done}" && [[ ${StepCount} -lt 11 ]]; do
            echo "Attempt to mv ${Input} to be done failed! Retrying..."
            sleep 10
            StepCount=$((${StepCount}+1))
        done
        echo "${Input} done"

    fi
}

function RemoteWorkspace {
    CopyJobsAndSpace=( $($SSH_command "
        ls -a ${RemoteLogDir}/.DeviceCopy_* ${RemoteLogDir}/DeviceCopy_* 2> /dev/null | grep -v done | wc -l
        eval $GetRemoteWorkSpace
    ") )

    CopyJobs=${CopyJobsAndSpace[0]}
    WorkSpace=${CopyJobsAndSpace[1]}
    SizeOfRunningCopyJobs=$((${CopyJobs} * ${Chunk} * ${BlockCount}))        
    echo $((${WorkSpace} - ${SizeOfRunningCopyJobs} - ${MinOperatingSystemSpace}))
}

function CreateImageFiles {
    Run=0

    while [[ ${Iterations[$Run]} ]] ; do

        if [ ! -e ${LogDir}/${JobTimeFile}_${Iterations[${Run}]}.run ] ; then

            Run=$((${Run} + 1))
            Skip=$((${Skip} + ${BlockCount}))

        else

            DDJobs=$(ls ${LogDir}/DeviceCopy_*.img 2> /dev/null | wc -l) || DDJobs=0 
            SizeOfRunningDDJobs=$((${DDJobs} * ${Chunk} * ${BlockCount}))        
            WorkSpace=$(eval $GetWorkSpace)
            WorkSpace=$((${WorkSpace} - ${SizeOfRunningDDJobs} - ${MinOperatingSystemSpace}))

            if [ $WorkSpace -gt $AvailableSpaceMin ] && [ ${DDJobs} -lt ${Cores} ] ; then

                TransferFile=${LogDir}/DeviceCopy_${Iterations[$Run]}_${Chunk}_${BlockCount}_${Skip}_${JobTimeFile}
                (dd_command From "${SourceDevice}" ${TransferFile}.img 2>&1 >> ${LogDir}/CreateImageFiles.log &)
                while [ ! -e ${TransferFile}.img ] ; do
                    sleep 2
                done
                Skip=$((${Skip} + ${BlockCount}))
                StartBlock=$((${StartBlock}+${SectorPortion}))
                Run=$((${Run} + 1))

            else

                sleep 5

            fi
        fi

    done
}

function Transfer() {
    File=$1
    mv -v ${File} ${File}.ongoing

    Image=${File##*/}
    echo Transfer start at $(date)
    if [[ "${UseS3}" == "" ]] ; then
        TransferCommand="$Rsync_command ${File}.ongoing ${TargetHost}:${RemoteLogDir}/${Image}"
        TransferCommandExitStatus=1
        TransferCommandLeave=0
        until [ $TransferCommandExitStatus -eq 0 ] || [ $TransferCommandLeave -eq 10 ] ; do 
            echo "Transfering ${File}"
            echo ${TransferCommand}
            eval $TransferCommand
            TransferCommandExitStatus=$?
            TransferCommandLeave=$((${TransferCommandLeave} + 1))
            sleep 3
        done
        echo "Rsync command exit status: ${TransferCommandExitStatus}"
    elif [[ "${UseS3}" == "yes" ]] ; then
        # TransferFileSize=$(stat -c %s ${File}.ongoing)
        TransferCommand="s3cmd -q --force put ${File}.ongoing s3://${TransferBucket}/${Image}.ongoing.s3"
        RemoteReceiveCommand="s3cmd -q --force get s3://${TransferBucket}/${Image}.ongoing.s3 ${RemoteLogDir}/${Image}.ongoing.s3"
        RemoveS3File="s3cmd del s3://${TransferBucket}/${File##*/}.ongoing.s3"
        echo "Starting transfer: $TransferCommand"
        eval $TransferCommand
        echo "Remote execution: ${RemoteReceiveCommand}"
        ${SSH_command} "$RemoteReceiveCommand" 2>&1 > /dev/null 
        #until (( $(${SSH_command} "stat -c %s ${RemoteLogDir}/${Image}.s3" || echo 0) >= ${TransferFileSize} )) ; do sleep 1 ; done
        sleep 1
        ${SSH_command} "mv -v ${RemoteLogDir}/${Image}.ongoing.s3 ${RemoteLogDir}/${Image}"
        echo "Removing S3 file: $RemoveS3File"
        eval $RemoveS3File
        echo "s3cmd put, receive and delete of ${Image}.s3 done."
    fi
    echo Transfer end at $(date)

    rm -v ${File}.ongoing
}

function SendFiles {
    sleep 5
    $SSH_command "[ -e ${RemoteLogDir} ] || mkdir ${RemoteLogDir}"

    while (ls ${LogDir}/${JobTimeFile}_*.run 2>&1 > /dev/null) \
        || (ps cax | grep "dd count") \
        || (ls ${LogDir}/*_${JobTimeFile}.img.transfer 2> /dev/null) ; do
        for TransferFile in $(ls ${LogDir}/*_${JobTimeFile}.img.transfer 2> /dev/null | head -n 1) ; do
            while [ "$(ps ax | grep -c -P '(rsync -e|s3cmd)')" -gt "${ProcessNumber}" ] ; do
                sleep 5
            done
            RunState=${TransferFile#*Copy_} ; RunState=${RunState%%_*}

            while [ $(RemoteWorkspace) -lt $AvailableSpaceMin ] \
                    || [[ $(ps ax | grep -c ssh) -gt ${MaxSSHConnections} ]] ; do
                    sleep 7
            done

            (Transfer $TransferFile 2>&1 >> ${LogDir}/SendFiles.log &)
            TMP=${LogDir}/${JobTimeFile}_${RunState}.run ; if [ ${TMP} ] ; then rm -v ${TMP} ; fi
        done
        sleep 3
    done

    s3cmd rb s3://${TransferBucket} 
}

function RemoteStatusImageToTargetDevice {

    export RemoteStatus=${RemoteLogDir}/RemoteStatusImageToTargetDevice.sh
    TmpStatusFile=${LogDir}/RemoteStatusImageToTargetDevice.sh
    $SSH_command "[ -e ${RemoteLogDir} ] || mkdir ${RemoteLogDir}"

    echo "
        one=\$(ls ${RemoteLogDir}/*.img.transfer ${RemoteLogDir}/*.img.transfer.s3 2> /dev/null | head -n 1)
        if [[ \"\$one\" == \"\" ]] ; then one=0 ; fi
        two=\$(ps cax | grep -c 'dd count=')
        three=\$(ls ${RemoteLogDir}/*_${JobTimeFile}.done ${RemoteLogDir}/*_${JobTimeFile}.img.transfer.ToDev.done 2> /dev/null | wc -l)
        echo \$one \$two \$three 
    " > ${TmpStatusFile}

    chmod a+x ${TmpStatusFile}
    $SCP_command ${TmpStatusFile} root@${TargetHost}:${RemoteStatus}
}

function ImageToTargetDevice {
    sleep 8 
    TargetCoreNumber=$($SSH_command "grep -c processor /proc/cpuinfo")

    while ! grep -P "Checksum step 0*1 local" ${Report} > /dev/null ; do
        sleep 5
    done

    RemoteStatusImageToTargetDevice

    while ls ${LogDir}/*_${JobTimeFile}.img* 2> /dev/null || $SSH_command "ls ${RemoteLogDir}/*.img.transfer ${RemoteLogDir}/*.img.transfer.s3 2> /dev/null" ; do

        Counter=0
        while
            FileAndProcessNumber=( $($SSH_command "bash ${RemoteStatus}") ) && \
            [[ ${FileAndProcessNumber[2]} -lt ${LastRun} ]] && \
            [[ $(ps ax | grep -c ssh) -le ${MaxSSHConnections} ]] 
            # && \
            # [[ ${Counter} -lt 120 ]]
        do 
            Counter=$((${Counter}+1))
            echo  FileAndProcessNumber ${FileAndProcessNumber[*]} 
            if [[ ${FileAndProcessNumber[0]} =~ "img.transfer" ]] && \
               [[ ${FileAndProcessNumber[1]} -lt $((${TargetCoreNumber}+1)) ]] && \
               [[ $($SSH_command "ls ${RemoteLogDir}/*.ToDev 2>/dev/null | wc -l") -lt $((${TargetCoreNumber}+1)) ]] ;
            then
                ImagePart=${FileAndProcessNumber[0]}.ToDev
                $SSH_command "mv -v ${FileAndProcessNumber[0]} ${ImagePart}"

                (dd_command To "${TargetDevice}" ${ImagePart} 2>&1 >> ${LogDir}/ToDeviceImageFiles.log &)

            fi
            sleep 1 
        done
        # if [[ ${Counter} -ge 120 ]] ; then echo "WARNING: Last run ${LastRun} not reached!" ; fi
        sleep 5

    done
}

function ReImage {
    Part=$1
    LocalChecksum=$(tac ${Report} | grep -m 1 -P "Checksum step ${Part} local is [a-z0-9]{64}" | cut -d ' ' -f6)
    Jump=$(grep -m 1 -o -P "Copy_${Part}_.*ToDev$" ${LogDir}/ToDeviceImageFiles.log | cut -d '_' -f 5)
    Check=$(grep -P "^ssh -p ${SSHPort} .*bs=${Chunk} skip=${Jump} " ${LogDir}/ToDeviceImageFiles.log)
    RemoteChecksum=$(eval ${Check} 2>/dev/null)
    RemoteChecksum=$(echo ${RemoteChecksum} | sed 's/ \-//')

    if [[ "${LocalChecksum}" == "${RemoteChecksum}" ]] ; then
        echo "Checksum step ${Part} remote is ${RemoteChecksum% -}" | tee -a ${Report}
        echo "Checksum step ${Part} is ok on both sides." | tee -a ${Report}
    else
        echo "WARNING: Checksum step ${Part} differs. Transfering mentioned part of the volume again."
        GetImagingAgain=$(grep "skip=${Jump} " ${LogDir}/CreateImageFiles.log | grep -v '^+')
        GetImagingAgain=$(echo ${GetImagingAgain} | sed 's/.img /.img.transfer.ongoing /')
        if [[ "${UseS3}" == "" ]] ; then
            Transfer=$(grep -P "^rsync.*DeviceCopy_${Part}_" ${LogDir}/SendFiles.log)
            Write=$(grep -P "^ssh -p ${SSHPort} .*bs=${Chunk} seek=${Jump}\"" ${LogDir}/ToDeviceImageFiles.log)
            Write=$(echo ${Write} | sed 's/.transfer.ToDev/.transfer/')
            Check=$(grep -P "^ssh -p ${SSHPort} .*bs=${Chunk} skip=${Jump} " ${LogDir}/ToDeviceImageFiles.log)
            LocalChecksum=$(eval ${GetImagingAgain} 2>/dev/null)
            echo "Checksum step ${Part} local is ${LocalChecksum% -}" | tee -a ${Report}
            eval ${Transfer}
            eval ${Write} 2>/dev/null
        elif [[ "${UseS3}" == "yes" ]] ; then
            echo ${GetImagingAgain} > ${LogDir}/ToDeviceImageFiles.log
            LocalChecksum=$(eval ${GetImagingAgain} 2>/dev/null)
            echo "Checksum step ${Part} local is ${LocalChecksum% -}" | tee -a ${Report}
            TransferFile=$(echo $GetImagingAgain | cut -d ' ' -f 14 | tr -d ')')
            echo "Transfering ${File} again."
            Transfer $TransferFile 2>&1 | tee -a ${LogDir}/SendFiles.log
            echo "Writing ${File} again."
            dd_command To "${TargetDevice}" ${File} 2>&1 | tee -a ${LogDir}/ToDeviceImageFiles.log
        fi  
        RemoteChecksum=$(eval ${Check} 2>/dev/null)
        if [[ "${LocalChecksum% -}" == "${RemoteChecksum% -}" ]] ; then
            echo "Checksum step ${Part} remote is ${RemoteChecksum% -}" | tee -a ${Report}
            echo "Checksum step ${Part} is ok on both sides." | tee -a ${Report}
        else
            echo "ERROR: Checksum step ${Part} still differs." | tee -a ${Report}
            ErrorSum=$(( ${ErrorSum} + 1 ))
        fi  
    fi  
    export ErrorSum=${ErrorSum}
}

function ShowProceeding {

    LocalProcess=true
    RemoteProcess=true
    sleep 5

    while [[ "${LocalProcess}" == "true" || "${RemoteProcess}" == "true" ]] ; do

        LocalFiles=$(ls ${LogDir}/*_${JobTimeFile}.img* ${LogDir}/*.run 2> /dev/null)
        if [[ "${LocalFiles}" == "" ]] ; then
            LocalProcess=false
            (echo "Last file send to remote device") | tee -a ${Report}  # why brackets?
        else
            echo "Local files in progress:"
            echo
            echo ${LocalFiles} | tr ' ' '\n' | grep -P '(transfer|img$)' | head -n 15
            echo
        fi

        RemoteFiles=$($SSH_command "ls -a ${RemoteLogDir}/*_${JobTimeFile}.* ${RemoteLogDir}/.*_${JobTimeFile}.* 2> /dev/null") 
        if [[ "$(echo ${RemoteFiles} | tr ' ' '\n' | grep -c .done)" == "${LastRun}" ]] ; then
            RemoteProcess=false
        else
            echo "Remote files in progress:"
            echo
            echo ${RemoteFiles} | tr ' ' '\n' | grep img | grep -v 'done' | head -n 15
            echo
        fi

        sleep 4
    done

    echo "Comparing data checksum results..."

    for i in $(seq -w ${LastRun}) ; do
        Local=$(grep -P "Checksum step ${i} local is " ${Report} | tail -n 1 | cut -d ' ' -f6)
        Remote=$(grep -P "Checksum step ${i} remote is " ${Report} | tail -n 1 | cut -d ' ' -f6)
        if [[ "${Local}" != "${Remote}" ]] || [[ "${Remote}" == "" ]] ; then
            echo "WARNING: Checksum for local and remote step ${i} is not identical!" | tee -a ${Report}
            echo "Attempt to fix will be initiated."
        fi
    done

    ErrorSum=0
    for CheckAgain in $(grep "is not identical" ${Report} | cut -d ' ' -f8 | sort | uniq) ; do
        ReImage ${CheckAgain};
    done

    echo "Job finished, ${ErrorSum} errors reported!" | tee -a ${Report}

    if [[ "${KeepLogs}" == "no" ]] && [[ ${ErrorSum} -eq 0 ]] ; then
        rm -rf ${LogDir}
        $SSH_command "rm -rf ${RemoteLogDir}"
    else
        echo "Check local ${LogDir} and remote ${RemoteLogDir} directory for details."
    fi
}

echo Start from image part ${StartBlock} to part ${LastRun} with ${Blocks} blocks at $JobTimeFile

CreateImageFiles 2>&1 >> ${LogDir}/CreateImageFiles.log &

SendFiles 2>&1 >> ${LogDir}/SendFiles.log &

ImageToTargetDevice 2>&1 >> ${LogDir}/ToDeviceImageFiles.log &

ShowProceeding
