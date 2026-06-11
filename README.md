# Win-VMS-report
This script identifies network performance degradation in Azure Windows VMs (high latency, connection drops/errors)

For True End-to-End Latency & Packet Loss
The script above uses available Azure metrics. If you need true latency and packet loss detection, enable:

Azure Monitor Network Insights (preview)

Network Watcher Connection Monitor (ICMP/TCP latency)

Diagnostic settings → Send to Log Analytics workspace

Then query AzureMetrics table for:

Avg of NetworkWatcher_ConnectionMonitor_LatencyMs

Total for NetworkWatcher_ConnectionMonitor_ProbeFailedPercent


