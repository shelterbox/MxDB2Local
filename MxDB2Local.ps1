# Backup API        : https://docs.mendix.com/apidocs-mxsdk/apidocs/backups-api/
# Deployment API    : https://docs.mendix.com/apidocs-mxsdk/apidocs/deploy-api/

# https://swimburger.net/blog/powershell/convertfrom-securestring-a-parameter-cannot-be-found-that-matches-parameter-name-asplaintext
Function ConvertFrom-SecureString-AsPlainText{
    [CmdletBinding()]
    param (
        [Parameter(
            Mandatory = $true,
            ValueFromPipeline = $true
        )]
        [System.Security.SecureString]
        $SecureString
    )
    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString);
    $PlainTextString = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr);
    $PlainTextString;
}

Clear-Host;
$userInput = $null;
$app = $null;
$environment = $null;
$snapshot = $null;

# Get inital variables and save in config
try {
    $c = Import-Clixml ".\MxDB2Local-Config.xml";
}
catch {
    Write-Host "Could not load configuration. Please supply settings."
    $c = @{
        "PGUSERNAME" = ""
        "PGPASSWORD" = ""
        "MXUSERNAME" = ""
        "MXAPIKEY" = ""
    };
    # PG (PostgresSQL) admin login
    $c.PGUSERNAME = Read-Host "Enter PostgresSQL username (postgres)"
    if ($c.PGUSERNAME -eq "") { $c.PGUSERNAME = "postgres" }
    while ($c.PGPASSWORD -eq "") { $c.PGPASSWORD = Read-Host "Enter PostgresSQL password" -AsSecureString }
    # MX (Mendix) API login
    while ($c.MXUSERNAME -eq "") { $c.MXUSERNAME = Read-Host "Enter Mendix username" }
    while ($c.MXAPIKEY -eq "") { $c.MXAPIKEY   = Read-Host "Enter Mendix API key" -AsSecureString }
    Export-Clixml -Path ".\MxDB2Local-Config.xml" -InputObject $c -Force;
}

# Set authentication parameters
$env:PGPASSWORD = ConvertFrom-SecureString-AsPlainText $c.PGPASSWORD;
$headers = @{
    "Mendix-Username" = $c.MXUSERNAME
    "Mendix-ApiKey" = ConvertFrom-SecureString-AsPlainText $c.MXAPIKEY
};

# Get app
$appResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/1/apps" -Headers $headers -Method Get;

while ($app -eq $null) {
    Write-Host "`nSelect the app :";

    # Display all available apps
    $n = 0;
    foreach ($x in $appResponse) {
        Write-Host "$($n) : $($x.Name)" -ForegroundColor Yellow;
        $n++;
    }

    $userInput = Read-Host;
    $app = $appResponse.Get($userInput);
}

# Get environment
$environmentResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/1/apps/$($app.AppId)/environments" -Headers $headers -Method Get;

while ($environment -eq $null) {
    Write-Host "`nSelect the environment : ";

    # Display all available environments
    $n = 0;
    foreach ($x in $environmentResponse) {
        Write-Host "$($n) : $($x.Mode)" -ForegroundColor Yellow;
        $n++;
    }

    $userInput = Read-Host;
    $environment = $environmentResponse.Get($userInput);
}

# Get snapshot
$snapshotResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/v2/apps/$($app.ProjectId)/environments/$($environment.EnvironmentId)/snapshots?offset=0&limit=10" -Headers $headers -Method Get;

while ($snapshot -eq $null) {
    Write-Host "`nSelect the snapshot : ";

    # Display all available environments
    $n = 0;
    foreach ($x in $snapshotResponse.snapshots) {
        $daysBetween = $((New-TimeSpan -Start (Get-Date -Date $x.created_at) -End (Get-Date)).Days);
        Write-Host "$($n) : $($x.model_version), $(Get-Date -Date $x.created_at -Format "ddd dd MMM yyyy HH:mm:ss") ($(if ($daysBetween -eq 0) {"Today"} elseif ($daysBetween -eq 1) {"$daysBetween day ago"} else {"$daysBetween days ago"}))" -ForegroundColor Yellow;
        $n++;
    }

    Write-Host "`n(Showing $($snapshotResponse.offset) to $($snapshotResponse.offset + $snapshotResponse.limit) of $($snapshotResponse.total))"
    if (($snapshotResponse.offset + $snapshotResponse.limit) -lt $snapshotResponse.total) {
        Write-Host "$n : Next page" -ForegroundColor Yellow;
        $n++;
    }
    if ($snapshotResponse.offset -ne 0) {
        Write-Host "$($n) : Previous page" -ForegroundColor Yellow;
    }

    $userInput = Read-Host;

    if ((($snapshotResponse.offset + $snapshotResponse.limit) -le $snapshotResponse.total) -and $userInput -eq ($n - 1)) {
        $snapshotResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/v2/apps/$($app.ProjectId)/environments/$($environment.EnvironmentId)/snapshots?offset=$($snapshotResponse.offset + $snapshotResponse.limit)&limit=$($snapshotResponse.limit)" -Headers $headers -Method Get;
    }
    elseif (($snapshotResponse.offset -ne 0) -and $userInput -eq $n) {
        $snapshotResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/v2/apps/$($app.ProjectId)/environments/$($environment.EnvironmentId)/snapshots?offset=$($snapshotResponse.offset - $snapshotResponse.limit)&limit=$($snapshotResponse.limit)" -Headers $headers -Method Get;
    }
    else {
        $snapshot = $snapshotResponse.snapshots.Get($userInput);
    }
}

# Calculate database name
$databaseName = "$($app.Name)-$($environment.Mode)".ToLower().Replace(" ", "_");

# Calculate unique name
$uniqueName = "$databaseName-$(Get-Date -Date $snapshot.created_at -Format "yyyyMMdd_HHmmss")";

# Calculate file locations
$originalLocation = Get-Location;
$output = "$(Get-Location)\TEMP";
$uniqueOutput = "$output\$uniqueName"
$fileName = "$uniqueName.tar.gz";
$fileLocation = "$output\$fileName";

# Check file doesn't exist already
if (-not (Test-Path -Path $fileLocation -PathType leaf)) {
    # Create archive for downloading
    $archiveResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/v2/apps/$($app.ProjectId)/environments/$($environment.EnvironmentId)/snapshots/$($snapshot.snapshot_id)/archives" -Headers $headers -Method Post;

    # Loop until archive is created successfully
    Write-Host;
    while (($archiveResponse.state -eq "queued") -or ($archiveResponse.state -eq "running")) {
        Start-Sleep -Seconds 2;
        $archiveResponse = Invoke-RestMethod -Uri "https://deploy.mendix.com/api/v2/apps/$($app.ProjectId)/environments/$($environment.EnvironmentId)/snapshots/$($snapshot.snapshot_id)/archives/$($archiveResponse.archive_id)" -Headers $headers -Method Get;
        Write-Host "Download is $($archiveResponse.state)" (&{If($archiveResponse.state -ne "completed") {"..."}});
    }

    # If an error occurs, stop the script
    if ($archiveResponse.state -eq "failed") {
        Write-Host $archiveResponse.status_message
        exit;
    }

    $download = $archiveResponse.url;

    # Create TEMP path if it doesn't exist
    if (-not (Test-Path -Path $output)) {
        $null = New-Item -Path $output -ItemType Directory
    }

    Write-Host "`nDownloading file to '$fileLocation' ...";
    Invoke-WebRequest -Uri $download -OutFile $fileLocation;
}

# Create unique output
if (-not (Test-Path -Path $uniqueOutput)) {
    $null = New-Item -Path $uniqueOutput -ItemType Directory
}

# Extract file to unique location
Write-Host "`nExtracting file to '$uniqueOutput' ...";
Set-Location $uniqueOutput;
tar -xf $fileLocation;
Set-Location $originalLocation;

# Drop existing database and create new
Write-Host "`nDropping '$databaseName' DB and creating new ...";
psql -U $c.PGUSERNAME -w -c "DROP DATABASE IF EXISTS """"$databaseName"""";";
psql -U $c.PGUSERNAME -w -c "CREATE DATABASE """"$databaseName"""";";

# Restore backup into SQL database
Write-Host "`nRestoring to DB '$databaseName' ...";
pg_restore -U $c.PGUSERNAME -O -w -d "$databaseName" "$uniqueOutput\db\db.backup";
Write-Host "Done"