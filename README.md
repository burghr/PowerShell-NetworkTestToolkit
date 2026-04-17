# PowerShell Network Test Toolkit

A PowerShell module for testing network connectivity -- TCP/UDP port testing, a local port listener for validating firewall rules, and bulk testing from CSV files.

## Functions

### `Start-PortListener`
Opens a TCP listener on a specified port and logs incoming connections with timestamps. Useful for confirming that traffic from a remote host is actually reaching a server through firewalls and load balancers.

```powershell
Start-PortListener -Port 443
# Listening on TCP port 443 -- press CTRL+C to stop
# Address         Port  DateTime
# 10.0.0.50      49832  4/16/2026 2:30:15 PM
```

### `Test-TCPPort`
Tests TCP connectivity to one or more hosts on one or more ports. Supports pipeline input and configurable timeout.

```powershell
Test-TCPPort -Computer "server01","server02" -Port 80,443,3389

# Server    Port Protocol  Open Notes
# server01    80      TCP  True
# server01   443      TCP  True
# server01  3389      TCP False Connection timed out
# server02    80      TCP  True
# ...
```

### `Test-UDPPort`
Tests UDP connectivity by sending a datagram and waiting for a response. Falls back to ICMP ping to distinguish between filtered ports and unreachable hosts.

```powershell
Test-UDPPort -Computer "10.0.0.1" -Port 53,161

# Server    Port Protocol  Open Notes
# 10.0.0.1    53      UDP  True
# 10.0.0.1   161      UDP  True No UDP response, but host is reachable via ICMP
```

### `Test-PortsFromCSV`
Bulk-tests outbound connectivity from a CSV of firewall rules. Column names are configurable to match your CSV layout.

```powershell
Test-PortsFromCSV -Path ".\firewall_rules.csv" -DestinationColumn "Dest IP" -PortColumn "Dest Port" -DirectionColumn "Direction"
# Testing 47 outbound rules...
# Results: 45 passed, 2 failed out of 47 tests
```

## Installation

```powershell
# Copy the module to your PowerShell modules directory
Copy-Item -Path .\NetworkTestToolkit.psm1 -Destination "$env:USERPROFILE\Documents\WindowsPowerShell\Modules\NetworkTestToolkit\NetworkTestToolkit.psm1"

# Or import directly
Import-Module .\NetworkTestToolkit.psm1
```

## CSV Format

For `Test-PortsFromCSV`, the default expected columns are `Destination`, `Port`, and `Direction`. Only rows where `Direction` contains "outbound" are tested. Use the `-DestinationColumn`, `-PortColumn`, and `-DirectionColumn` parameters if your CSV uses different column names.

```csv
Destination,Port,Direction
10.0.0.1,443,Outbound
10.0.0.2,1433,Outbound
10.0.0.3,80,Inbound
```

## Use Cases

- **Firewall change validation** -- after a firewall change, bulk-test all expected rules from a spreadsheet
- **Migration readiness** -- verify connectivity from a new environment before cutover
- **Troubleshooting** -- run the listener on one side and test from the other to isolate where traffic is being dropped
- **Audit** -- periodically test that expected ports are still open (or closed)
