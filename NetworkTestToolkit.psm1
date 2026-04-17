function Start-PortListener {
    <#
    .SYNOPSIS
    Opens a TCP listener on a specified port and logs incoming connections.

    .DESCRIPTION
    Binds a TCP socket to the specified port on all interfaces and waits for incoming
    connections. Each connection is logged with the remote endpoint and timestamp.
    Useful for verifying firewall rules, testing connectivity from remote hosts,
    or confirming that traffic is reaching a server on a given port.

    Press CTRL+C to stop the listener. The socket is cleaned up safely on exit.

    .PARAMETER Port
    The TCP port number to listen on. Defaults to 80.

    .EXAMPLE
    Start-PortListener -Port 443
    Listens on TCP/443 and logs any incoming connection attempts.

    .EXAMPLE
    Start-PortListener 8080
    Listens on TCP/8080.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Position = 0)]
        [ValidateRange(1, 65535)]
        [int]$Port = 80
    )

    $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, $Port)
    $listener = New-Object System.Net.Sockets.TcpListener $endpoint
    $listener.Server.ReceiveTimeout = 3000
    $listener.Start()

    try {
        Write-Host "Listening on TCP port $Port -- press CTRL+C to stop" -ForegroundColor Cyan
        while ($true) {
            if (-not $listener.Pending()) {
                Start-Sleep -Seconds 1
                continue
            }
            $client = $listener.AcceptTcpClient()
            $client.Client.RemoteEndPoint |
                Add-Member -NotePropertyName DateTime -NotePropertyValue (Get-Date) -PassThru |
                Select-Object Address, Port, DateTime
            $client.Close()
        }
    }
    catch {
        Write-Error $_
    }
    finally {
        $listener.Stop()
        Write-Host "Listener closed safely" -ForegroundColor Yellow
    }
}

function Test-TCPPort {
    <#
    .SYNOPSIS
    Tests TCP connectivity to one or more hosts on one or more ports.

    .DESCRIPTION
    Attempts a TCP connection to each combination of computer and port.
    Returns a report object for each test with the connection result.

    .PARAMETER Computer
    One or more hostnames or IP addresses to test.

    .PARAMETER Port
    One or more TCP port numbers to test.

    .PARAMETER Timeout
    Connection timeout in milliseconds. Defaults to 2000.

    .EXAMPLE
    Test-TCPPort -Computer "server01","server02" -Port 80,443
    Tests HTTP and HTTPS connectivity to both servers.

    .EXAMPLE
    "10.0.0.1","10.0.0.2" | Test-TCPPort -Port 3389
    Tests RDP connectivity via pipeline input.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string[]]$Computer,

        [Parameter(Mandatory, Position = 1)]
        [ValidateRange(1, 65535)]
        [int[]]$Port,

        [Parameter()]
        [int]$Timeout = 2000
    )

    Begin {
        $report = @()
    }

    Process {
        foreach ($c in $Computer) {
            foreach ($p in $Port) {
                $result = [PSCustomObject]@{
                    Server   = $c
                    Port     = $p
                    Protocol = "TCP"
                    Open     = $false
                    Notes    = ""
                }

                try {
                    $tcpClient = New-Object System.Net.Sockets.TcpClient
                    $connect = $tcpClient.BeginConnect($c, $p, $null, $null)
                    $wait = $connect.AsyncWaitHandle.WaitOne($Timeout, $false)

                    if ($wait -and $tcpClient.Connected) {
                        $result.Open = $true
                        $tcpClient.EndConnect($connect)
                    }
                    else {
                        $result.Notes = "Connection timed out"
                    }
                    $tcpClient.Close()
                }
                catch {
                    $result.Notes = $_.Exception.Message
                }

                $report += $result
            }
        }
    }

    End {
        $report
    }
}

function Test-UDPPort {
    <#
    .SYNOPSIS
    Tests UDP connectivity to one or more hosts on one or more ports.

    .DESCRIPTION
    Sends a UDP datagram to each combination of computer and port and waits
    for a response. Because UDP is connectionless, a lack of response does not
    necessarily mean the port is closed -- the host may simply not reply.

    .PARAMETER Computer
    One or more hostnames or IP addresses to test.

    .PARAMETER Port
    One or more UDP port numbers to test.

    .PARAMETER Timeout
    Receive timeout in milliseconds. Defaults to 2000.

    .EXAMPLE
    Test-UDPPort -Computer "10.0.0.1" -Port 53,161
    Tests DNS and SNMP UDP ports on a host.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline)]
        [string[]]$Computer,

        [Parameter(Mandatory, Position = 1)]
        [ValidateRange(1, 65535)]
        [int[]]$Port,

        [Parameter()]
        [int]$Timeout = 2000
    )

    Begin {
        $report = @()
    }

    Process {
        foreach ($c in $Computer) {
            foreach ($p in $Port) {
                $result = [PSCustomObject]@{
                    Server   = $c
                    Port     = $p
                    Protocol = "UDP"
                    Open     = $false
                    Notes    = ""
                }

                try {
                    $udpClient = New-Object System.Net.Sockets.UdpClient
                    $udpClient.Client.ReceiveTimeout = $Timeout
                    $udpClient.Connect($c, $p)

                    # Send a probe datagram
                    $encoding = New-Object System.Text.ASCIIEncoding
                    $bytes = $encoding.GetBytes("$(Get-Date)")
                    [void]$udpClient.Send($bytes, $bytes.Length)

                    # Wait for a response
                    $remoteEndpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
                    try {
                        $receiveBytes = $udpClient.Receive([ref]$remoteEndpoint)
                        $returnData = $encoding.GetString($receiveBytes)
                        $result.Open = $true
                        $result.Notes = $returnData
                    }
                    catch {
                        if ($_.Exception.InnerException -match "period of time") {
                            # Timeout -- host may be up but not responding on UDP
                            if (Test-Connection -ComputerName $c -Count 1 -Quiet) {
                                $result.Open = $true
                                $result.Notes = "No UDP response, but host is reachable via ICMP"
                            }
                            else {
                                $result.Notes = "No response -- host may be unreachable or port filtered"
                            }
                        }
                        elseif ($_.Exception.InnerException -match "forcibly closed") {
                            $result.Notes = "Port closed (ICMP unreachable received)"
                        }
                        else {
                            $result.Notes = $_.Exception.Message
                        }
                    }

                    $udpClient.Close()
                }
                catch {
                    $result.Notes = $_.Exception.Message
                }

                $report += $result
            }
        }
    }

    End {
        $report
    }
}

function Test-PortsFromCSV {
    <#
    .SYNOPSIS
    Bulk-tests port connectivity from a CSV file.

    .DESCRIPTION
    Reads a CSV with columns for destination host, port, and direction, then tests
    each outbound entry. Returns a report with pass/fail status for each row.

    The CSV must have at minimum these columns (names are configurable):
    - A column for the destination IP or hostname
    - A column for the destination port
    - A column for direction (inbound/outbound) -- only outbound rows are tested

    .PARAMETER Path
    Path to the CSV file.

    .PARAMETER DestinationColumn
    Name of the CSV column containing the destination IP/hostname. Defaults to "Destination".

    .PARAMETER PortColumn
    Name of the CSV column containing the port number. Defaults to "Port".

    .PARAMETER DirectionColumn
    Name of the CSV column containing the direction. Defaults to "Direction".
    Only rows where this value contains "outbound" are tested.

    .PARAMETER Timeout
    TCP connection timeout in milliseconds. Defaults to 2000.

    .EXAMPLE
    Test-PortsFromCSV -Path ".\firewall_rules.csv"
    Tests all outbound rules in the CSV using default column names.

    .EXAMPLE
    Test-PortsFromCSV -Path ".\rules.csv" -DestinationColumn "Dest IP" -PortColumn "Dest Port" -DirectionColumn "Inbound or Outbound"
    Tests with custom column names matching your CSV layout.
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory, Position = 0)]
        [ValidateScript({ Test-Path $_ })]
        [string]$Path,

        [Parameter()]
        [string]$DestinationColumn = "Destination",

        [Parameter()]
        [string]$PortColumn = "Port",

        [Parameter()]
        [string]$DirectionColumn = "Direction",

        [Parameter()]
        [int]$Timeout = 2000
    )

    $csv = Import-Csv $Path
    $outbound = $csv | Where-Object { $_.$DirectionColumn -like "*outbound*" }

    if (-not $outbound) {
        Write-Warning "No outbound entries found in CSV. Check your DirectionColumn parameter ('$DirectionColumn')."
        return
    }

    Write-Host "Testing $($outbound.Count) outbound rules..." -ForegroundColor Cyan

    $results = @()
    foreach ($entry in $outbound) {
        $dest = $entry.$DestinationColumn
        $port = $entry.$PortColumn

        if (-not $dest -or -not $port) {
            Write-Warning "Skipping row with missing destination or port"
            continue
        }

        $testResult = Test-TCPPort -Computer $dest -Port ([int]$port) -Timeout $Timeout
        $results += $testResult
    }

    $passed = ($results | Where-Object { $_.Open }).Count
    $failed = ($results | Where-Object { -not $_.Open }).Count
    Write-Host "`nResults: $passed passed, $failed failed out of $($results.Count) tests" -ForegroundColor $(if ($failed -eq 0) { "Green" } else { "Yellow" })

    $results
}

Export-ModuleMember -Function Start-PortListener, Test-TCPPort, Test-UDPPort, Test-PortsFromCSV
