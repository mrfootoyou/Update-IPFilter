# Update-IPFilter

A cross-platform PowerShell 7+ module to download IPFilter file from
<http://upd.emule-security.org/> then update a running qBittorrent instance to
use the filters. The filters will only be updated if a newer version is
available.

Example usage:

```powershell
Import-Module ./Update-IPFilter.psm1

# Simple: Update a local unprotected qBittorrent server running in
# host context (not a container):
Update-IPFilter 'http://localhost:8083' -DestinationPath './ipfilter.dat' -PassThru

# Complex: Update a secured qBittorrent server running in a container
# with a mounted /data volume and custom domain.
# The function will prompt for the server password.
Update-IPFilter `
  -ServerUrl 'https://qbt.example.com/' `
  -UserName '...' `
  -DestinationPath 'M:/Multimedia/Torrents/IPFilter/ipfilter.dat' `
  -ServerPath '/data/Torrents/IPFilter/ipfilter.dat'
```

Windows users can use `Register-UpdateIPFilter` to create a scheduled task to
update the IPFilter on a regular basis:

```powershell
Import-Module .\Update-IPFilter.psm1

# Define the Update-IPFilter arguments (see above):
$updateIPFilterArgs = @{
  ServerUrl = 'https://qbt.example.com/'
  UserName = '...'
  DestinationPath = 'M:/Multimedia/Torrents/IPFilter/ipfilter.dat'
  ServerPath = '/data/Torrents/IPFilter/ipfilter.dat'
}

# Simple: Create the default scheduled task (Sundays at 8 AM):
$task = Register-UpdateIPFilter @updateIPFilterArgs -ShowTaskWindow -PassThru

# Complex: Use a custom schedule (daily at 3 AM):
$trigger = New-ScheduledTaskTrigger -Daily -At (Get-Date '3:00 AM')
$task = Register-UpdateIPFilter @updateIPFilterArgs -TaskTrigger $trigger -ShowTaskWindow -PassThru

# Optional: Run the scheduled task immediately:
$task | Start-ScheduledTask
```

Use the `Unregister-UpdateIPFilter` function to delete the scheduled task when
it is no longer needed.
