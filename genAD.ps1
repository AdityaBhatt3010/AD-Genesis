param(
    [Parameter(Mandatory=$true)] [string]$JSONFile,
    [string]$DCServer,
    [PSCredential]$WorkstationCredential,
    [switch]$Undo
)

# Import Active Directory module on MC
Import-Module ActiveDirectory -ErrorAction Stop

# Load JSON
if (!(Test-Path -LiteralPath $JSONFile)) {
    throw "JSON file not found: $JSONFile"
}

$json = Get-Content -LiteralPath $JSONFile -Raw | ConvertFrom-Json

# Discover domain information from DC
if ($DCServer) {
    $domain = Get-ADDomain -Server $DCServer -ErrorAction Stop
}
else {
    $domain = Get-ADDomain -ErrorAction Stop
}

$Global:Domain = $domain.DNSRoot
$Global:NetBIOSDomain = $domain.NetBIOSName
$script:ADServer = $domain.PDCEmulator
$script:ManagedDescription = "Created by genAD.ps1"

# Validate domain
if ($json.domain -ne $Global:Domain) {
    throw "JSON domain '$($json.domain)' does not match AD domain '$Global:Domain'"
}

Write-Host "Connected to domain: $Global:Domain"
Write-Host "NetBIOS domain: $Global:NetBIOSDomain"
Write-Host "Domain Controller: $script:ADServer"

# Generate username from full name
function Get-LabUsername {
    param(
        [Parameter(Mandatory=$true)] [string]$Name
    )

    $parts = $Name.Trim() -split '\s+', 2

    if ($parts.Count -ne 2 -or !$parts[0] -or !$parts[1]) {
        throw "Invalid user name format: $Name"
    }

    $username = ($parts[0].Substring(0,1) + $parts[1]).ToLowerInvariant()

    if ($username.Length -gt 20) {
        throw "Generated SamAccountName exceeds 20 characters: $username"
    }

    return $username
}

# Perform local administrator changes on a workstation
function Invoke-WorkstationLocalAdminChange {
    param(
        [Parameter(Mandatory=$true)] [string]$ComputerName,
        [Parameter(Mandatory=$true)] [string]$Member,
        [switch]$Remove
    )

    $remoteBlock = {
        param(
            [string]$Member,
            [bool]$Remove
        )

        $existingMember = Get-LocalGroupMember -Group "Administrators" -ErrorAction Stop | Where-Object { $_.Name -ieq $Member }

        if ($Remove) {

            if ($existingMember) {
                Remove-LocalGroupMember -Group "Administrators" -Member $Member -Confirm:$false -ErrorAction Stop
                $status = "Removed"
            }
            else {
                $status = "Not present"
            }

        }
        else {

            if ($existingMember) {
                $status = "Already a member"
            }
            else {
                Add-LocalGroupMember -Group "Administrators" -Member $Member -ErrorAction Stop
                $status = "Added"
            }
        }

        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            Member = $Member
            Action = if ($Remove) { "Remove" } else { "Add" }
            Status = $status
        }
    }

    $invokeParams = @{
        ComputerName = $ComputerName
        ScriptBlock = $remoteBlock
        ArgumentList = @($Member, [bool]$Remove.IsPresent)
        ErrorAction = "Stop"
    }

    if ($WorkstationCredential) {
        $invokeParams.Credential = $WorkstationCredential
    }

    Invoke-Command @invokeParams
}

# Create AD group
function CreateADGroup {
    param(
        [Parameter(Mandatory=$true)] $groupObject
    )

    $name = $groupObject.name

    New-ADGroup -Name $name -GroupScope Global -GroupCategory Security -Description $script:ManagedDescription -Server $script:ADServer -ErrorAction Stop | Out-Null

    Write-Host "Created AD group: $name" -ForegroundColor Green
}

# Remove AD group
function RemoveADGroup {
    param(
        [Parameter(Mandatory=$true)] $groupObject
    )

    $name = $groupObject.name

    $group = Get-ADGroup -Identity $name -Server $script:ADServer -Properties Description -ErrorAction SilentlyContinue

    if (!$group) {
        Write-Warning "Group $name does not exist"
        return
    }

    if ($group.Description -ne $script:ManagedDescription) {
        Write-Warning "Skipping $name because it was not created by this script"
        return
    }

    Remove-ADGroup -Identity $name -Server $script:ADServer -Confirm:$false -ErrorAction Stop

    Write-Host "Removed AD group: $name" -ForegroundColor Yellow
}

# Create AD user
function CreateADUser {
    param(
        [Parameter(Mandatory=$true)] $userObject
    )

    $name = $userObject.name
    $password = $userObject.password

    $parts = $name.Trim() -split '\s+', 2

    if ($parts.Count -ne 2 -or !$parts[0] -or !$parts[1]) {
        throw "Invalid user name format: $name"
    }

    $firstname = $parts[0]
    $lastname = $parts[1]

    $username = Get-LabUsername -Name $name
    $samAccountName = $username
    $principalname = "$username@$Global:Domain"

    # Create AD user
    New-ADUser -Name $name -GivenName $firstname -Surname $lastname -SamAccountName $samAccountName -UserPrincipalName $principalname -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) -Enabled $true -Description $script:ManagedDescription -Server $script:ADServer -ErrorAction Stop

    Write-Host "Created AD user: $username" -ForegroundColor Green

    # Add user to assigned AD groups
    foreach ($groupName in @($userObject.groups)) {

        if ([string]::IsNullOrWhiteSpace([string]$groupName)) {
            continue
        }

        Get-ADGroup -Identity $groupName -Server $script:ADServer -ErrorAction Stop | Out-Null

        Add-ADGroupMember -Identity $groupName -Members $samAccountName -Server $script:ADServer -ErrorAction Stop

        Write-Host "Added $username to AD group $groupName" -ForegroundColor Green
    }

    # Add user to specified workstation Administrators groups
    foreach ($hostname in @($userObject.local_admin)) {

        if ([string]::IsNullOrWhiteSpace([string]$hostname)) {
            continue
        }

        $account = "$Global:NetBIOSDomain\$username"

        Write-Host "Assigning $account as local administrator on $hostname"

        Invoke-WorkstationLocalAdminChange -ComputerName $hostname -Member $account
    }
}

# Remove AD user and local administrator memberships
function RemoveADUser {
    param(
        [Parameter(Mandatory=$true)] $userObject
    )

    $name = $userObject.name
    $username = Get-LabUsername -Name $name

    $user = Get-ADUser -Identity $username -Server $script:ADServer -Properties Description -ErrorAction SilentlyContinue

    if (!$user) {
        Write-Warning "User $username does not exist"
        return
    }

    if ($user.Description -ne $script:ManagedDescription) {
        Write-Warning "Skipping $username because it was not created by this script"
        return
    }

    # Remove workstation local administrator memberships first
    foreach ($hostname in @($userObject.local_admin)) {

        if ([string]::IsNullOrWhiteSpace([string]$hostname)) {
            continue
        }

        $account = "$Global:NetBIOSDomain\$username"

        Write-Host "Removing $account from local Administrators on $hostname"

        Invoke-WorkstationLocalAdminChange -ComputerName $hostname -Member $account -Remove
    }

    # Remove AD user
    Remove-ADUser -Identity $username -Server $script:ADServer -Confirm:$false -ErrorAction Stop

    Write-Host "Removed AD user: $username" -ForegroundColor Yellow
}

# Main execution
if (-not $Undo) {

    Write-Host "Starting AD provisioning..." -ForegroundColor Cyan

    # Create all groups first
    foreach ($group in $json.groups) {
        CreateADGroup $group
    }

    # Create users, memberships and workstation assignments
    foreach ($user in $json.users) {
        CreateADUser $user
    }

    Write-Host "AD provisioning completed." -ForegroundColor Green

}
else {

    Write-Host "Starting AD cleanup..." -ForegroundColor Cyan

    # Remove users and workstation memberships first
    foreach ($user in $json.users) {
        RemoveADUser $user
    }

    # Remove generated groups
    foreach ($group in $json.groups) {
        RemoveADGroup $group
    }

    Write-Host "AD cleanup completed." -ForegroundColor Green
}
