# Author: Pascal Neubauer
# Contact: pascal.neubauer@cloud.ionos.com
# Organization: Ionos SE
# License: GPL3

# This script aims to help you collect network related basic system information which is necessary to investigate 
# issues on a VM that runs on the IONOS cloud compute engine but have only reduced or no network connectivity.
# It should be usable for any other Windows installation anywhere as well.

param ([string] $RemoteHost = "185.48.118.10")
	
echo "This script will now create an overview of your network settings, please forward the output to support@cloud.ionos.com"

#Logfile
$hostname = hostname
$Logfile = $hostname + ".log"
$User = $env:Username
if (Test-Path -Path c:\Users\$User\AppData\Local\Temp) {
	$cleanup = "0"
	$log = "c:\Users\$User\AppData\Local\Temp\$Logfile"
}
elseif (Test-Path -Path c:\Temp) {
	$cleanup = "0"
	$log = "c:\Temp\$Logfile"
}
else {
	$cleanup = "1"
	New-Item -Path "c:\" -Name "Temp" -ItemType Directory |Out-Null
	$log = "c:\Temp\$Logfile"
}

#define functions
function FirewallReadout {

	Get-NetFirewallRule -Enabled True |Where-Object {$_.Owner -like ""} |
	Format-Table -AutoSize -Property DisplayName,
	@{Name='Protocol';Expression={($PSItem |Get-NetFirewallPortFilter).Protocol}},
	@{Name='LocalPort';Expression={($PSItem |Get-NetFirewallPortFilter).LocalPort}},
	@{Name='RemotePort';Expression={($PSItem |Get-NetFirewallPortFilter).RemotePort}},
	@{Name='RemoteAddress';Expression={($PSItem |Get-NetFirewallAddressFilter).RemoteAddress}},
	Direction,
	Action |Out-String -Width 1000
 }

 function Ifconfigs {

	Get-NetIPInterface |Sort-Object -Property IfIndex |Format-Table -AutoSize IfIndex,InterfaceAlias,AddressFamily,NlMtu,Dhcp,
    @{Name='IPAddress';Expression={($PSItem |Get-NetIPAddress).IPAddress}},
    @{Name='Status';Expression={($PSItem |Get-NetAdapter).Status}},
	@{Name='MacAddress';Expression={($PSItem |Get-NetAdapter).MacAddress}}
   }

#define Ccommands to run
$date = date
$ver = [Environment]::OSVersion
$virtio = Get-WmiObject Win32_PnPSignedDriver |Where-Object {$_.DeviceName -like "*VirtIO*"} |Select DeviceName,DriverVersion
$neigh = Get-NetNeighbor |Sort-Object -Property IfIndex|Format-Table ifIndex,IPAddress,LinkLayerAddress,State
$iflist =  Ifconfigs
$route = Get-NetRoute
$DNS = Get-NetIPConfiguration |Select-Object -ExpandProperty DNSServer
$TCPConnection = Get-NetTCPConnection |select LocalPort, RemoteAddress, RemotePort, State |Format-Table
$UDPConnection = Get-NetUDPEndpoint
$hosts =  cat 'c:\Windows\System32\drivers\etc\hosts'
$tracert = Test-NetConnection -ComputerName "$RemoteHost" -TraceRoute -InformationLevel Detailed
$Firewall = FirewallReadout

#create the array to loop through
$CommandList = @($date,$ver,$virtio,$neigh,$iflist,$route,$DNS,$TCPConnection,$UDPConnection,$hosts, $tracert, $Firewall)
$Commands = ("Date/Time","Windows Version","VirtIO Driver","IP Neighbor","List of Interfaces","Route","DNS-Servers","TCP Conenctions","UDP","Host File","Traceroute","Firewall Settings")


#create the logfile
echo "Please forward this Log to support@cloud.ionos.com" >> $log
echo `t >> $log


for ($i=0; $i -lt $CommandList.length; $i++) {
	echo $Commands[$i] >> $log
	echo $CommandList[$i] >> $log
	echo `t >> $log
}

start $log
#cleanup
start-Sleep -Seconds 2
Remove-Item $log
if ($cleanup -eq "1") {
Remove-Item -Path "c:\Temp"
} 