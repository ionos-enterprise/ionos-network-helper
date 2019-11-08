#!/bin/bash
# Author: Georg Schieche-Dirik
# Contact: georg.schieche-dirik@cloud.ionos.com
# Organization: 1&1 IONOS Cloud GmbH
# License: GPL3

# This script aims to help you collect network related basic system information which is necessary to investigate issues on VM that run on the 1&1 IONOS platform but have only reduced or no network connectivity.

# It should be usable for any other Linux installation anywhere as well.

function ShowHelp {

    if [[ $LANG =~ de ]] ; then
        echo
        echo "Anwendung:"
        echo
        echo "$0 [-p|--pause [Anhalten zwischen den einzelnen Kommandos]] [-t|--targethost Zieladresse] [-h|--help [Anzeigen dieser Hilfe]]"
        echo
        echo "Als Ziele sollten öffentlich erreichbare IP-Adressen gewählt werden wie z. B. 185.48.118.10 (profitbricks.de)."
        echo
        echo "Die Option -p hält den Programmablauf an, damit die Ausgabe mittels Screenshot festgehalten werden kann."
        echo
    else
        echo
        echo "Usage:"
        echo
        echo "$0 [-p|--pause [pause after each cammand execution]] [-t|--targethost host_to_test]"
        echo "[-h|--help [print this help message]]"
        echo
        echo "As target host you should prefer a publicly reachable IP address, for example 185.48.118.10 (profitbricks.de)."
        echo
        echo "The pause option -p pauses the command execution for taking screenshots of each console output one after another."
        echo
    fi
}

TargetHost=185.48.118.10

ResultFile=/tmp/support_$(hostname)_$(date +%s).log

while test $# -gt 0 ; do

    case "$1" in
        -p|--pause)
            Pause="echo 'Please type enter to proceed.' ; read";
            shift ;;
        -h|--help)
            ShowHelp;
            exit ;;
        -t|--targethost) shift;
            TargetHost=$1;
            if [[ "$TargetHost" == "" ]] ; then
                ShowHelp
                exit 2
            fi ;
            shift ;;
        *) ShowHelp;
            exit 2 ;;
    esac

done

CommandList=(
    "date"
    "uname -a"
    "cat /etc/os-release"
    "arp -n"
    "ip address list"
    "ip route show"
    "ip neighbour show"
    "iptables --list --numeric --verbose"
    "cat /etc/sysconfig/network*/ifcfg-eth*"
    "cat /etc/network/interfaces"
    "cat /etc/resolv.conf"
    "netstat --tcp --numeric -a"
    "netstat --udp --numeric -a"
    "ping -c 5 localhost"
    "mtr -n -r $TargetHost"
    "ping -c 5 $TargetHost"
)

function CheckNetwork {

for i in $(seq 0 $((${#CommandList[*]}-1))) ; do
    TopLine=$(echo ${CommandList[$i]} | tr '[:print:]' '=')
    echo
    echo "========${TopLine}========"
    echo "======= ${CommandList[$i]} ======= "
    echo
    eval ${CommandList[$i]}
    echo
    eval $Pause
done

}

CheckNetwork | tee $ResultFile

echo
if [[ $LANG =~ de ]] ; then
    echo "Wenn Sie ein Supportticket eröffnen möchten, senden Sie bitte eine E-Mail an enterprise-support@ionos.com und hängen Sie die Datei ${ResultFile} oder Screenshots der Kommandoausgaben an die E-Mail."
else
    echo "If you would like to open a ticket for the 1&1 IONOS support, please write an e-mail to enterprise-support@ionos.com and attach the file ${ResultFile} or the screenshots of the command output to it."
fi
echo

