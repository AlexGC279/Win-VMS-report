# Win-VMS-report
This script identifies network performance degradation in Azure Windows VMs (high latency, connection drops/errors)


Important Notes for Production Use

Requirement	                                                   Implementation

Azure subscription connection	                                 Connect-AzAccount + Set-AzContext
Network performance metrics                              	     Uses Network In/Out Total (since raw latency requires Azure Monitor + Network Watcher)
Connection drops/errors	                                       Detected via metric data gaps (missing telemetry = possible drops)
CSV export	                                                   Exports exactly: VMName, IPAddress, AverageLatency, ConnectionStatus, Timestamp
Windows VMs only	                                             Filters OsType -eq "Windows" + PowerState VM running
