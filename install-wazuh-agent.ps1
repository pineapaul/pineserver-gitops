<#
.SYNOPSIS
  Automated Wazuh agent install and configuration for pineserver home lab.

.DESCRIPTION
  - Downloads and installs the Wazuh Windows agent MSI
  - Registers with the Wazuh manager running in K3s on pineserver
  - Uses NodePort 31515/TCP for enrollment
  - Configures the agent to send events to wazuh.pineserver.local:1514/TCP
  - Restarts the agent service

  Tested against:
  - Manager: wazuh.pineserver.local (192.168.0.42)
  - Wazuh in K3s, with:
      * wazuh-auth-nodeport: 1515:31515/TCP
      * host proxy: 1514/TCP -> wazuh-manager-worker:1514/TCP
#>

param(
    [string]$AgentName      = $env:COMPUTERNAME,
    [string]$ManagerHost    = 'wazuh.pineserver.local',
    [int]   $RegPort        = 31515,                  # NodePort for enrollment (1515 inside cluster)
    [int]   $EventPort      = 1514,                   # Host port proxied to wazuh-manager-worker:1514
    [string]$RegPassword    = 'WazuhPineServer123!',  # MUST match /var/ossec/etc/authd.pass
    [string]$AgentVersion   = '4.11.1-1',             # Adjust if you upgrade Wazuh
    [switch]$ForceReinstall
)

# ---------------------------
# Helper: Ensure running as Administrator
# ---------------------------
function Assert-Admin {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal   = New-Object Security.Principal.WindowsPrincipal($currentUser)

    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
        Write-Error "This script must be run as Administrator. Right-click PowerShell and choose 'Run as administrator'."
        exit 1
    }
}

# ---------------------------
# Helper: Download file
# ---------------------------
function Download-File {
    param(
        [Parameter(Mandatory=$true)][string]$Url,
        [Parameter(Mandatory=$true)][string]$Destination
    )

    Write-Host "Downloading Wazuh agent MSI from: $Url"
    Invoke-WebRequest -Uri $Url -OutFile $Destination -UseBasicParsing
}

# ---------------------------
# STEP 0: Pre-flight checks
# ---------------------------
Assert-Admin

Write-Host "=== Wazuh Agent Install for pineserver ===" -ForegroundColor Cyan
Write-Host "Agent name    : $AgentName"
Write-Host "Manager host  : $ManagerHost"
Write-Host "Enroll port   : $RegPort (NodePort -> 1515 inside cluster)"
Write-Host "Event port    : $EventPort (proxied host port -> 1514 in K3s)"
Write-Host "Agent version : $AgentVersion"
Write-Host ""

# ---------------------------
# STEP 1: Test connectivity to manager host
# ---------------------------
Write-Host "Testing basic connectivity to $ManagerHost ..." -ForegroundColor Yellow
try {
    $dns = Resolve-DnsName -Name $ManagerHost -ErrorAction Stop
    Write-Host "DNS OK. $ManagerHost resolves to: $($dns.IPAddress)" -ForegroundColor Green
} catch {
    Write-Warning "DNS resolution for $ManagerHost failed. The install may still work if you fix DNS later, but ideally fix DNS first."
}

# ---------------------------
# STEP 2: Download MSI
# ---------------------------
$msiFileName = "wazuh-agent-$AgentVersion.msi"
$msiUrl      = "https://packages.wazuh.com/4.x/windows/$msiFileName"
$msiLocal    = Join-Path $env:TEMP $msiFileName

if (Test-Path $msiLocal -and -not $ForceReinstall) {
    Write-Host "MSI already downloaded at $msiLocal (use -ForceReinstall to re-download)." -ForegroundColor Yellow
} else {
    if (Test-Path $msiLocal) {
        Remove-Item $msiLocal -Force
    }
    Download-File -Url $msiUrl -Destination $msiLocal
}

# ---------------------------
# STEP 3: Install / reconfigure Wazuh agent via MSI
# ---------------------------
Write-Host "Installing / configuring Wazuh agent via MSI..." -ForegroundColor Yellow

$msiArgs = @(
    "/i `"$msiLocal`""
    "/qn"
    "WAZUH_MANAGER=$ManagerHost"
    "WAZUH_REGISTRATION_SERVER=$ManagerHost"
    "WAZUH_REGISTRATION_PORT=$RegPort"
    "WAZUH_REGISTRATION_PASSWORD=$RegPassword"
    "WAZUH_AGENT_NAME=$AgentName"
)

$process = Start-Process -FilePath "msiexec.exe" -ArgumentList $msiArgs -Wait -PassThru

if ($process.ExitCode -ne 0) {
    Write-Error "msiexec exited with code $($process.ExitCode). Check MSI logs or try rerunning with -ForceReinstall."
    exit 1
}

Write-Host "MSI finished. Checking for Wazuh service (WazuhSvc)..." -ForegroundColor Green

# ---------------------------
# STEP 4: Ensure Wazuh service exists and is running
# ---------------------------
$service = Get-Service -Name "WazuhSvc" -ErrorAction SilentlyContinue

if (-not $service) {
    Write-Error "WazuhSvc service not found after install. Something went wrong."
    exit 1
}

if ($service.Status -ne 'Running') {
    Write-Host "Starting WazuhSvc service..." -ForegroundColor Yellow
    Start-Service -Name "WazuhSvc"
    Start-Sleep -Seconds 5
}

# ---------------------------
# STEP 5: Fix ossec.conf client section (events to 1514/TCP)
# ---------------------------
Write-Host "Configuring ossec.conf client section..." -ForegroundColor Yellow

$configPath = "C:\Program Files (x86)\ossec-agent\ossec.conf"

if (-not (Test-Path $configPath)) {
    Write-Error "ossec.conf not found at $configPath. Is the Wazuh agent installed correctly?"
    exit 1
}

[xml]$xml = Get-Content -Path $configPath

# Ensure <ossec_config> root exists
if (-not $xml.ossec_config) {
    Write-Error "Invalid ossec.conf structure (missing <ossec_config> root)."
    exit 1
}

# Ensure <client> exists
$clientNode = $xml.ossec_config.client
if (-not $clientNode) {
    Write-Host "No <client> node found. Creating one..." -ForegroundColor Yellow
    $clientNode = $xml.CreateElement("client")
    $xml.ossec_config.AppendChild($clientNode) | Out-Null
}

# Ensure <server> exists inside <client>
$serverNode = $clientNode.server
if (-not $serverNode) {
    Write-Host "No <server> node found under <client>. Creating one..." -ForegroundColor Yellow
    $serverNode = $xml.CreateElement("server")
    $clientNode.AppendChild($serverNode) | Out-Null
}

# Helper to create or update a simple leaf element under <server>
function Set-ServerChildNode {
    param(
        [xml]$XmlDoc,
        [System.Xml.XmlElement]$Server,
        [string]$Name,
        [string]$Value
    )

    $node = $Server.$Name
    if (-not $node) {
        $node = $XmlDoc.CreateElement($Name)
        $Server.AppendChild($node) | Out-Null
    }
    $node.InnerText = $Value
}

Set-ServerChildNode -XmlDoc $xml -Server $serverNode -Name "address"  -Value $ManagerHost
Set-ServerChildNode -XmlDoc $xml -Server $serverNode -Name "port"     -Value $EventPort.ToString()
Set-ServerChildNode -XmlDoc $xml -Server $serverNode -Name "protocol" -Value "tcp"

# Save the updated config
$xml.Save($configPath)
Write-Host "Updated $configPath with address=$ManagerHost, port=$EventPort, protocol=tcp" -ForegroundColor Green

# ---------------------------
# STEP 6: Restart Wazuh service to apply config
# ---------------------------
Write-Host "Restarting WazuhSvc to apply configuration..." -ForegroundColor Yellow
Restart-Service -Name "WazuhSvc" -Force
Start-Sleep -Seconds 5

# ---------------------------
# STEP 7: Basic connectivity check from this client
# ---------------------------
Write-Host "Testing connectivity to event port $EventPort on $ManagerHost ..." -ForegroundColor Yellow
try {
    $test = Test-NetConnection -ComputerName $ManagerHost -Port $EventPort -WarningAction SilentlyContinue
    if ($test.TcpTestSucceeded) {
        Write-Host "TCP connectivity to $ManagerHost:$EventPort OK." -ForegroundColor Green
    } else {
        Write-Warning "TCP connectivity to $ManagerHost:$EventPort FAILED. Check pineserver proxy and firewall."
    }
} catch {
    Write-Warning "Test-NetConnection raised an error: $_"
}

Write-Host ""
Write-Host "Wazuh agent installation script completed." -ForegroundColor Cyan
Write-Host "On pineserver, verify with:" -ForegroundColor Cyan
Write-Host "  sudo kubectl -n wazuh exec -it wazuh-manager-master-0 -- /var/ossec/bin/agent_control -l" -ForegroundColor Cyan
Write-Host "You should see this client with Status: Active." -ForegroundColor Cyan
