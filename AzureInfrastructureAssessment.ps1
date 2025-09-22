#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute
param(
  [string[]]$SubscriptionIds = @(),
  [string]$ExportPath = "AzureInfrastructureAssessment_$(Get-Date -Format 'yyyy-MM-dd-HH-mm').csv",
  [switch]$DetailedReport,
  [switch]$ExportToExcel
)

function Get-RgAndNameFromId {
  param([Parameter(Mandatory)] [string]$ResourceId)
  $parts = $ResourceId.Trim('/').Split('/')
  $rgIdx = [Array]::IndexOf($parts, 'resourceGroups') + 1
  $provIdx = [Array]::IndexOf($parts, 'providers') + 1
  @{
    ResourceGroupName = $parts[$rgIdx]
    ProviderNamespace = $parts[$provIdx]
    Type1 = $parts[$provIdx + 1]
    Name1 = $parts[$provIdx + 2]
    Type2 = if ($parts.Length -gt $provIdx + 3) { $parts[$provIdx + 3] } else { $null }
    Name2 = if ($parts.Length -gt $provIdx + 4) { $parts[$provIdx + 4] } else { $null }
  }
}

function Get-SubnetById {
  param([Parameter(Mandatory)] [string]$SubnetId)
  $meta = Get-RgAndNameFromId -ResourceId $SubnetId
  # For subnets: .../virtualNetworks/<vnet>/subnets/<subnet>
  $vnetName   = $meta.Name1
  $subnetName = $meta.Name2
  $rg         = $meta.ResourceGroupName
  $vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rg -ErrorAction Stop
  return ($vnet.Subnets | Where-Object { $_.Name -eq $subnetName })
}

function Get-NicById {
  param([Parameter(Mandatory)] [string]$NicId)
  $meta = Get-RgAndNameFromId -ResourceId $NicId
  return Get-AzNetworkInterface -Name $meta.Name1 -ResourceGroupName $meta.ResourceGroupName -ErrorAction Stop
}

function Get-RouteTableById {
  param([Parameter(Mandatory)] [string]$RouteTableId)
  $meta = Get-RgAndNameFromId -ResourceId $RouteTableId
  return Get-AzRouteTable -Name $meta.Name1 -ResourceGroupName $meta.ResourceGroupName -ErrorAction Stop
}

function Get-PublicIpById {
  param([Parameter(Mandatory)] [string]$PipId)
  $meta = Get-RgAndNameFromId -ResourceId $PipId
  return Get-AzPublicIPAddress -Name $meta.Name1 -ResourceGroupName $meta.ResourceGroupName -ErrorAction Stop
}

# Initialize
$assessmentResults = @()
$totalVMsAssessed = 0
$totalBasicIPs = 0
$totalDefaultOutbound = 0

Write-Host "🚀 Starting Azure Infrastructure Assessment for September 30, 2025 Changes" -ForegroundColor Green
Write-Host "Assessment Time: $(Get-Date)" -ForegroundColor Yellow

# Subscriptions
if ($SubscriptionIds.Count -eq 0) {
  $subscriptions = Get-AzSubscription | Where-Object {$_.State -eq "Enabled"}
  Write-Host "📋 Assessing ALL enabled subscriptions ($($subscriptions.Count) total)" -ForegroundColor Cyan
} else {
  $subscriptions = $SubscriptionIds | ForEach-Object { Get-AzSubscription -SubscriptionId $_ }
  Write-Host "📋 Assessing specified subscriptions ($($subscriptions.Count) total)" -ForegroundColor Cyan
}

foreach ($subscription in $subscriptions) {
  Write-Host "`n🔍 Processing Subscription: $($subscription.Name) ($($subscription.Id))" -ForegroundColor Magenta
  try {
    Set-AzContext -SubscriptionId $subscription.Id | Out-Null

    Write-Host "   📡 Analyzing Default Outbound Access usage..." -ForegroundColor White
    $vms = Get-AzVM
    $totalVMsAssessed += $vms.Count

    foreach ($vm in $vms) {
      $vmAssessment = [PSCustomObject]@{
        SubscriptionName = $subscription.Name
        SubscriptionId   = $subscription.Id
        ResourceGroup    = $vm.ResourceGroupName
        VMName           = $vm.Name
        VMId             = $vm.Id
        Location         = $vm.Location
        HasDefaultOutboundAccess = $false
        HasBasicSKUIP    = $false
        PublicIPCount    = 0
        BasicIPCount     = 0
        NetworkInterfaces = @()
        OutboundMethods   = @()
        SecurityConcerns  = @()
        RecommendedActions = @()
        ComplianceStatus  = "UNKNOWN"
      }

      foreach ($nicRef in $vm.NetworkProfile.NetworkInterfaces) {
        try {
          $nic = Get-NicById -NicId $nicRef.Id
          $nicAnalysis = [PSCustomObject]@{
            NICName        = $nic.Name
            HasPublicIP    = $false
            HasLoadBalancer= $false
            HasNATGateway  = $false
            HasNVARoute    = $false
            PublicIPs      = @()
          }

          foreach ($ipConfig in $nic.IpConfigurations) {
            # Public IP
            if ($ipConfig.PublicIPAddress) {
              try {
                $publicIP = Get-PublicIpById -PipId $ipConfig.PublicIPAddress.Id
                $nicAnalysis.HasPublicIP = $true
                $vmAssessment.PublicIPCount++

                # Robust Basic/Standard detection
                $isBasic = $false
                if ($publicIP.Sku -and $publicIP.Sku.Name) {
                  $isBasic = ($publicIP.Sku.Name -eq 'Basic')
                } else {
                  # If Sku is null, treat as Basic (older Basic PIPs often have null Sku in some Az versions)
                  $isBasic = $true
                }

                $publicIPDetails = [PSCustomObject]@{
                  Name             = $publicIP.Name
                  SKU              = if ($publicIP.Sku) { $publicIP.Sku.Name } else { 'Basic (inferred)' }
                  AllocationMethod = $publicIP.PublicIPAllocationMethod
                  IPAddress        = $publicIP.IPAddress
                  IsBasicSKU       = $isBasic
                }
                $nicAnalysis.PublicIPs += $publicIPDetails

                if ($isBasic) {
                  $vmAssessment.BasicIPCount++
                  $vmAssessment.HasBasicSKUIP = $true
                  $totalBasicIPs++
                }
              } catch {
                Write-Warning "Failed to read Public IP on NIC '$($nic.Name)': $($_.Exception.Message)"
              }
            }

            # LB backend pool bound?
            if ($ipConfig.LoadBalancerBackendAddressPools -and $ipConfig.LoadBalancerBackendAddressPools.Count -gt 0) {
              $nicAnalysis.HasLoadBalancer = $true
              $vmAssessment.OutboundMethods += "Load Balancer"
            }

            # Subnet-level checks (NATGW, UDR)
            if ($ipConfig.Subnet -and $ipConfig.Subnet.Id) {
              try {
                $subnet = Get-SubnetById -SubnetId $ipConfig.Subnet.Id

                # NAT Gateway present?
                if ($subnet.NatGateway -and $subnet.NatGateway.Id) {
                  $nicAnalysis.HasNATGateway = $true
                  $vmAssessment.OutboundMethods += "NAT Gateway"
                }

                # UDR 0.0.0.0/0 to NVA?
                if ($subnet.RouteTable -and $subnet.RouteTable.Id) {
                  $routeTable = Get-RouteTableById -RouteTableId $subnet.RouteTable.Id
                  $defaultRoutes = $routeTable.Routes | Where-Object {
                    $_.AddressPrefix -eq "0.0.0.0/0" -and $_.NextHopType -eq "VirtualAppliance"
                  }
                  if ($defaultRoutes) {
                    $nicAnalysis.HasNVARoute = $true
                    $vmAssessment.OutboundMethods += "Network Virtual Appliance"
                  }
                }
              } catch {
                Write-Warning "Failed to analyze subnet/UDR for NIC '$($nic.Name)': $($_.Exception.Message)"
              }
            }
          }

          $vmAssessment.NetworkInterfaces += $nicAnalysis
        } catch {
          Write-Warning "Failed to analyze NIC $($nicRef.Id): $($_.Exception.Message)"
        }
      }

      # Default Outbound (no explicit method discovered)
      $hasExplicitOutbound = ($vmAssessment.NetworkInterfaces | Where-Object {
        $_.HasPublicIP -or $_.HasLoadBalancer -or $_.HasNATGateway -or $_.HasNVARoute
      }).Count -gt 0

      $vmAssessment.HasDefaultOutboundAccess = -not $hasExplicitOutbound
      if ($vmAssessment.HasDefaultOutboundAccess) {
        $totalDefaultOutbound++
        $vmAssessment.SecurityConcerns += "Uses default outbound access (will be retired Sept 30, 2025)"
        $vmAssessment.RecommendedActions += "Configure explicit outbound connectivity (NAT Gateway recommended)"
      }

      if ($vmAssessment.HasBasicSKUIP) {
        $vmAssessment.SecurityConcerns += "Uses Basic SKU Public IPs (will be retired Sept 30, 2025)"
        $vmAssessment.RecommendedActions += "Upgrade to Standard SKU Public IPs before Sept 30, 2025"
      }

      $vmAssessment.ComplianceStatus = if ($vmAssessment.HasDefaultOutboundAccess -or $vmAssessment.HasBasicSKUIP) { "NON-COMPLIANT" } else { "COMPLIANT" }
      $assessmentResults += $vmAssessment
    }

    Write-Host "   ✅ Completed assessment for $($vms.Count) VMs" -ForegroundColor Green
  } catch {
    Write-Error "Failed to assess subscription $($subscription.Name): $($_.Exception.Message)"
  }
}

# Summary
Write-Host "`n📊 ASSESSMENT SUMMARY" -ForegroundColor Yellow
Write-Host "===========================================" -ForegroundColor Yellow
Write-Host "Total VMs Assessed: $totalVMsAssessed" -ForegroundColor White
Write-Host "VMs Using Default Outbound Access: $totalDefaultOutbound" -ForegroundColor Red
Write-Host "Basic SKU Public IPs Found: $totalBasicIPs" -ForegroundColor Red

$n
