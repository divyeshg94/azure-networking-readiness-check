# azure-networking-readiness-check
PowerShell scanner that flags Azure VMs using Default Outbound Access and Basic SKU Public IPs, and reports remediation readiness for the Sept 30, 2025 retirements.


# Azure 2025 Readiness Scanner 🛡️🚀
[![PowerShell](https://img.shields.io/badge/powershell-7%2B-blue)]()
[![Az Modules](https://img.shields.io/badge/Requires-Az.Accounts%2C%20Az.Network%2C%20Az.Compute%2C%20Az.Resources-blueviolet)]()
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)]()
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-brightgreen.svg)]()

Scan your Azure subscriptions for resources affected by the **September 30, 2025** networking retirements:
- **Default Outbound Access** removal (VMs must use explicit outbound egress like **NAT Gateway**, **Standard Public IP**, **Load Balancer**, or **NVA/UDR**).
- **Basic SKU Public IP** deprecation (migrate to **Standard**).

This script inventories your VMs, detects risks, and exports a **CSV/Excel** report with **clear remediation guidance**.

---

## ✨ Features
- 🔎 Detects **Default Outbound Access** usage per VM/NIC/subnet
- 🧪 Flags **Basic SKU Public IPs** (including legacy objects where `Sku` may be null)
- 🧭 Identifies outbound methods in use: **NAT Gateway**, **Load Balancer**, **NVA (UDR to VirtualAppliance)**, **Public IP**
- 📊 Exports results to **CSV** (and **.xlsx** if `ImportExcel` is installed)
- 🧮 Provides **subscription- and fleet-level compliance summaries**
- 🧰 Works across **all enabled subscriptions** or a provided list

---

## 📦 Requirements
- **PowerShell 7+** (Windows/Linux/macOS)  
- **Az modules**: `Az.Accounts`, `Az.Resources`, `Az.Network`, `Az.Compute`  
  ```powershell
  Install-Module Az -Scope CurrentUser

---

# 1) Sign in
Connect-AzAccount

# 2) Run against all enabled subscriptions (CSV)
.\AzureInfrastructureAssessment.ps1

# 3) Run against specific subscriptions and export to Excel
$subs = @('00000000-0000-0000-0000-000000000000','11111111-1111-1111-1111-111111111111')
.\AzureInfrastructureAssessment.ps1 -SubscriptionIds $subs -ExportToExcel

# 4) More details in the CSV (one row per VM with nested JSON-like columns)
.\AzureInfrastructureAssessment.ps1 -DetailedReport

---

🧠 What the scanner checks (per VM)

1) Presence of explicit outbound egress
- NAT Gateway attached to subnet
- Load Balancer backend association
- UDR 0.0.0.0/0 → VirtualAppliance (NVA)
- Public IP (and whether it’s Basic or Standard)
2) Flags HasDefaultOutboundAccess if no explicit method found
3) Summarizes SecurityConcerns and RecommendedActions
4) Sets ComplianceStatus = COMPLIANT / NON-COMPLIANT


---

