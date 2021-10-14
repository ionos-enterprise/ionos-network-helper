#!/bin/bash

# Author: Georg Schieche-Dirik
# Contact: georg.schieche-dirik@ionos.com
# Organization: Ionos SE
# License: GPL3

# This script aims to help you collect network related basic system information which is necessary to investigate 
# issues on a VM that runs on the IONOS cloud compute engine but have only reduced or no network connectivity.
# It should be usable for any other Linux installation anywhere as well.

function ShowHelp {
    if [[ $LANG =~ de ]] ; then
        echo
        echo "Anwendung:"
        echo
        echo "$0 [-p|--pause [Anhalten zwischen den einzelnen Kommandos]] [-t|--targethost Zieladresse]"
        echo "[--host6 [IPv6-Adresse als Zielhost]]"
        echo "[-6|--IPv6 [IPv6-Verbindung prüfen]]"
        echo "[-h|--help [Anzeigen dieser Hilfe]]"
        echo
        echo "Als Ziele sollten öffentlich erreichbare IP-Adressen gewählt werden wie z. B." 
        echo "185.48.116.14 (dcd.ionos.com)." 
        echo
        echo "Die Option -p hält den Programmablauf an, damit die Ausgabe mittels Screenshot festghalten werden kann."
        echo
    else 
        echo
        echo "Usage:"
        echo
        echo "$0 [-p|--pause [pause after each cammand execution]] [-t|--targethost host_to_test]" 
        echo "[--host6 [us IPv6 address as target]]"
        echo "[-6|--IPv6 [check IPv6 connectivity]]"
        echo "[-h|--help [print this help message]]"
        echo
        echo "As target host you should prefer a publicly reachable IP address, for" 
        echo "example 217.160.86.33 (dcd.ionos.com)." 
        echo
        echo "The pause option -p pauses the command execution for taking screenshots" 
        echo "of each console output one after another."
        echo
    fi
}

TargetHost4=185.48.116.14
TargetHost6=2a02:247a::42:34

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
            TargetHost4=$1;
            if [[ "$TargetHost4" == "" ]] ; then
                ShowHelp
                exit 2
            fi ;
            shift ;;
        -6|--IPv6) 
            IPv6=true
            shift ;;
        --host6) shift;
            TargetHost6=$1;
            if [[ "$TargetHost6" == "" ]] ; then
                ShowHelp
                exit 2
            fi ;
            shift ;;
         *) ShowHelp;
            exit 2 ;;
    esac
done

function CommandListIPv4 {
    CommandList=(
        "date"
        "uname -a"
        "cat /etc/os-release"
        "iptables --list --numeric --verbose"
        "cat /etc/sysconfig/network*/ifcfg-*"
        "cat /etc/network/interfaces"
        "cat /etc/resolv.conf"
        "cat /etc/hosts"
        "time nslookup $TargetHost4"
        "time nslookup ietf.com"
        "ip -4 neigh"
        "ip -4 address list"
        "ip -4 route show"
        "ip -4 neighbour show"
        "ss -4 --tcp --process --all --numeric"
        "ss -4 --udp --process --all --numeric"
        "ping -4 -c 5 $TargetHost4"
        "ping -c 5 localhost"
        "if which mtr > /dev/null ; then mtr -4 -n -r $TargetHost4 ; else traceroute -4 -M icmp $TargetHost4 ; fi"
    )
}

function CommandListIPv6 {
    CommandList=(
        "ip -6 neigh"
        "ip -6 address list"
        "ip -6 route show"
        "ip -6 neighbour show"
        "ss -6 --tcp --process --all --numeric"
        "ss -6 --udp --process --all --numeric"
        "ip6tables --list --numeric --verbose"
        "ping6 -c 5 localhost"
        "if which mtr > /dev/null ; then mtr -6 -n -r $TargetHost6 ; else traceroute -6 -M icmp $TargetHost6 ; fi"
        "time nslookup $TargetHost6"
        "ping6 -c 5 $TargetHost6"
    )
}

function CheckNetwork {
    if [[ $1 == "4" ]] ; then 
        CommandListIPv4
    elif [[ $1 == "6" ]] ; then 
        CommandListIPv6
    fi 
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

CheckNetwork 4 2>&1 | tee -a $ResultFile

if [[ ${IPv6} == "true" ]] || [[ ${TargetHost6} != "2a02:247a::42:34" ]] ; then
    CheckNetwork 6 2>&1 | tee -a $ResultFile
fi

echo 

if [[ $LANG =~ de ]] ; then
   echo "Wenn Sie ein Supportticket eröffnen möchten, senden Sie bitte eine E-Mail an support@cloud.ionos.com"
   echo "und hängen Sie die Datei ${ResultFile} oder Screenshots der Kommandoausgaben an die E-Mail."
else 
   echo "If you would like to open a ticket for the IONOS cloud support, please write an e-mail to support@cloud.ionos.com"
   echo "and attach the file ${ResultFile} or the screenshots of the command output to it."
fi

echo 
