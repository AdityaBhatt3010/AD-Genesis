param(
    [Parameter(Mandatory=$true)] [string]$OutputJSONFile,
    [int]$UserCount = 5,
    [int]$GroupCount = 1,
    [int]$LocalAdminCount = 0,
    [string[]]$Workstations = @()
)

# Validate input counts
if ($UserCount -lt 1) {
    throw "UserCount must be at least 1"
}

if ($GroupCount -lt 1) {
    throw "GroupCount must be at least 1"
}

if ($LocalAdminCount -lt 0) {
    throw "LocalAdminCount cannot be negative"
}

if ($LocalAdminCount -gt $UserCount) {
    throw "LocalAdminCount cannot exceed UserCount"
}

# Normalize workstation names and remove duplicates
$Workstations = @($Workstations | ForEach-Object { $_.Trim() } | Where-Object { $_ } | Select-Object -Unique)

if ($LocalAdminCount -gt 0 -and $Workstations.Count -eq 0) {
    throw "Workstations must be supplied when LocalAdminCount is greater than 0"
}

# Load input data
$group_names = [System.Collections.ArrayList](Get-Content "data/group_names.txt")
$first_names = [System.Collections.ArrayList](Get-Content "data/first_names.txt")
$last_names = [System.Collections.ArrayList](Get-Content "data/last_names.txt")
$passwords = [System.Collections.ArrayList](Get-Content "data/passwords.txt")

# Validate available data
if ($GroupCount -gt $group_names.Count) {
    throw "GroupCount exceeds the number of available group names"
}

if ($UserCount -gt $first_names.Count -or $UserCount -gt $last_names.Count) {
    throw "UserCount exceeds the number of available first or last names"
}

if ($UserCount -gt $passwords.Count) {
    throw "UserCount exceeds the number of available passwords"
}

# Initialize collections
$groups = @()
$users = @()

# Select unique indexes for local admin users
$local_admin_indexes = @()

for ($i = 1; $i -le $LocalAdminCount; $i++) {

    $random_index = Get-Random -InputObject (1..$UserCount)

    if ($local_admin_indexes -contains $random_index) {
        $i--
        continue
    }

    $local_admin_indexes += $random_index

    Write-Host "Adding $random_index to local_admin_indexes: $local_admin_indexes"
}

# Generate AD groups
for ($i = 1; $i -le $GroupCount; $i++) {

    $group_name = Get-Random -InputObject $group_names

    $group = @{
        "name" = "$group_name"
    }

    $groups += $group

    [void]$group_names.Remove($group_name)
}

# Generate AD users
for ($i = 1; $i -le $UserCount; $i++) {

    $first_name = Get-Random -InputObject $first_names
    $last_name = Get-Random -InputObject $last_names
    $password = Get-Random -InputObject $passwords

    $selected_group = Get-Random -InputObject $groups

    $new_user = @{
        "name" = "$first_name $last_name"
        "password" = "$password"
        "groups" = @($selected_group.name)
        "local_admin" = @()
    }

    # Assign workstations to selected local admin users
    if ($local_admin_indexes -contains $i) {

        Write-Host "User $i is a local admin on: $Workstations"

        $new_user["local_admin"] = @($Workstations)
    }

    $users += $new_user

    [void]$first_names.Remove($first_name)
    [void]$last_names.Remove($last_name)
    [void]$passwords.Remove($password)
}

# Generate final JSON
$jsonOutput = @{
    "domain" = "Adi.com"
    "groups" = $groups
    "users" = $users
} | ConvertTo-Json -Depth 5

# Create output directory if necessary
$outputDirectory = Split-Path -Parent $OutputJSONFile

if ($outputDirectory -and !(Test-Path $outputDirectory)) {
    New-Item -Path $outputDirectory -ItemType Directory -Force | Out-Null
}

# Export JSON
Set-Content -Path $OutputJSONFile -Value $jsonOutput -Encoding UTF8

Write-Host "JSON successfully generated at $OutputJSONFile" -ForegroundColor Green
Write-Host "Generated Users: $UserCount | Groups: $GroupCount | Local Admin Users: $LocalAdminCount"
