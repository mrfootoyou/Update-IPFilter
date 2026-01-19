#requires -Version 7
Set-StrictMode -Version Latest

function Install-LatestIPFilter {
    <#
    .DESCRIPTION
        Downloads and extract the latest IPFilter file to a specified path.
        It uses ETag headers to avoid unnecessary downloads when the file is up to date.
    #>
    [CmdletBinding(PositionalBinding = $false, SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([System.IO.FileInfo])]
    param(
        # Path to save the downloaded IPFilter file. Defaults to './ipfilter.dat'.
        [Parameter(Position = 1)]
        [string] $DestinationPath = './ipfilter.dat',
        # URL of the IPFilter source ZIP file. Defaults to 'http://upd.emule-security.org/ipfilter.zip'.
        [uri] $SourceUrl = 'http://upd.emule-security.org/ipfilter.zip',
        # Name of the IPFilter file inside the ZIP archive. Defaults to 'guarding.p2p'.
        [string] $SourceFile = 'guarding.p2p',
        # Name of the file to store the ETag value. Defaults to 'source.etag' in the same folder as DestinationPath.
        [string] $EtagFileName = 'source.etag',
        # If specified, forces update even if the IPFilter file is up to date.
        [switch] $Force
    )

    $DestinationPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DestinationPath)
    if (Test-Path $DestinationPath -PathType Container) {
        Write-Error -Exception 'DestinationPath cannot be a folder.'
        return
    }

    # Prepare path variables
    $destDir = Split-Path $DestinationPath -Parent
    $etagFile = Join-Path $destDir $EtagFileName
    $tempDir = Join-Path ([System.IO.Path]::GetTempPath()) ([Guid]::NewGuid())
    $zipPath = Join-Path $tempDir 'source.zip'
    $p2pPath = Join-Path $tempDir $SourceFile

    # Prepare request headers
    $reqHeaders = @{}
    if (!$Force -and (Test-Path $etagFile) -and (Test-Path $DestinationPath)) {
        try {
            Write-Verbose "Reading etag from '$etagFile'"
            $etag = Get-Content $etagFile -ea Stop
            $reqHeaders['If-None-Match'] = $etag
            Write-Verbose "Using If-None-Match: $etag"
        }
        catch {
            Write-Warning "Failed to read etag from '$etagFile': $_"
        }
    }

    if (!$PSCmdlet.ShouldProcess($DestinationPath)) { return }
    # Suppress remaining confirmations...
    $ConfirmPreference = 'None'

    Write-Verbose "Downloading $SourceUrl to '$zipPath'"
    $null = New-Item $tempDir -ItemType Directory -Force -ea Stop
    try {
        $req = @{
            Uri                = $SourceUrl
            Headers            = $reqHeaders
            OutFile            = $zipPath
            SkipHttpErrorCheck = $true # to handle 304 Not Modified
            PassThru           = $true # to get ETag
            Verbose            = $false
        }
        $resp = Invoke-WebRequest @req
        if (!$resp) { return } # error already handled
        $resp.BaseResponse | Write-Verbose
        if ($resp.StatusCode -eq 304) {
            Write-Information "IPFilter is up to date (HTTP 304 Not Modified)."
            return Get-Item $DestinationPath | Add-Member 'Updated' $false -PassThru
        }
        if ($resp.StatusCode -ne 200) {
            Write-Error -Exception "Failed to download ${SourceUrl}: $($resp.StatusCode) - $($resp.StatusDescription)"
            return
        }
        $etag = "$($resp.Headers.ETag)"

        Write-Verbose "Expanding '$zipPath'"
        if (!(Expand-Archive -LiteralPath $zipPath -DestinationPath $tempDir -Force -ea Stop -Verbose:$false -PassThru)) {
            return # error already handled
        }
        if (!(Test-Path $p2pPath)) {
            Write-Error -Exception "Source file '$SourceFile' not found in $SourceUrl."
            return
        }

        Write-Verbose "Copying '$p2pPath' to '$DestinationPath'"
        if (!(Test-Path $destDir) -and !$WhatIfPreference) {
            $null = New-Item $destDir -ItemType Directory -Force -ea Stop
        }
        if (!(Copy-Item -LiteralPath $p2pPath -Destination $DestinationPath -Force -PassThru)) {
            return # error already handled
        }
        if ($etag) {
            Write-Verbose "Saving ETag to '$etagFile': $etag"
            $etag | Out-File $etagFile -Encoding utf8 -Force -ea Continue
        }

        Write-Information "IPFilter downloaded to '$DestinationPath'."
        return Get-Item $DestinationPath | Add-Member 'Updated' $true -PassThru
    }
    finally {
        Remove-Item $tempDir -Force -Recurse -ea Continue
    }
}

function getQbtUsername {
    Read-Host -Prompt 'Qbittorrent username' -ea Stop
}
function getQbtPassword {
    Read-Host -Prompt 'Qbittorrent password' -MaskInput -ea Stop
}

function Get-QBittorrentCookie {
    <#
    .DESCRIPTION
        Logs into qBittorrent Web API and retrieves the session cookie.
    #>
    [CmdletBinding(PositionalBinding = $false)]
    param(
        # qBittorrent server URL. Defaults to 'http://localhost:8083'.
        [uri] $ServerUrl = 'http://localhost:8083',
        # Username for the qBittorrent server. If not specified, prompts for username.
        [string] $UserName,
        # Password for the qBittorrent server user. If not specified, prompts for password.
        # Empty password is allowed.
        [AllowEmptyString()]
        [string] $UserPass
    )

    if (!$UserName) { $UserName = getQbtUsername }
    if (!$PSBoundParameters.ContainsKey('UserPass')) { $UserPass = getQbtPassword }

    # Login API returns 200 OK with content 'Ok.' on success.
    # On auth failure, it returns 200 OK with content 'Fails.'
    # On other errors, it returns appropriate HTTP status codes.
    Write-Verbose "Logging into $ServerUrl as $UserName..."
    $loginUrl = [uri]::new($ServerUrl, 'api/v2/auth/login')
    $formData = @{
        username = $UserName
        password = $UserPass
    }
    $resp = Invoke-WebRequest $loginUrl -Method Post -Form $formData -SkipHttpErrorCheck -Verbose:$false
    if (!$resp) { return } # error already handled
    $resp.BaseResponse | Write-Verbose
    if (!$resp.BaseResponse.IsSuccessStatusCode) {
        Write-Error -Exception "Login failed: $($resp.StatusCode) - $($resp.Content)"
        return
    }
    if ($resp.Content -ne 'Ok.') {
        Write-Error -Exception "Unauthorized ($($resp.Content))"
        return
    }

    if (!$resp.Headers.ContainsKey('Set-Cookie')) {
        # Should not happen if login succeeded
        throw 'Set-Cookie header not received from qBittorrent.'
    }

    return ($resp.Headers['Set-Cookie'][0] -split ';')[0]
}

function Update-QBittorrentPreferences {
    <#
    .DESCRIPTION
        Updates qBittorrent preferences via its Web API.
        Specifically, it can enable/disable IP filtering and set the path to the IPFilter file.
    #>
    [CmdletBinding(PositionalBinding = $false, SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        # qBittorrent server URL. Defaults to 'http://localhost:8083'.
        [uri] $ServerUrl = 'http://localhost:8083',
        # Username for the qBittorrent server.
        [string] $UserName,
        # Password for the qBittorrent server user.
        # If not specified and UserName is provided, then prompts for password.
        [AllowEmptyString()]
        [string] $UserPass,

        # Path to the IPFilter file relative to the qBittorrent server.
        # Passing an empty string disables IP filtering.
        [AllowEmptyString()]
        [string] $IPFilterPath
    )

    $preferences = @{}
    if ($PSBoundParameters.ContainsKey('IPFilterPath')) {
        $preferences['ip_filter_enabled'] = !!$IPFilterPath
        $preferences['ip_filter_path'] = $IPFilterPath
    }

    $headers = @{}
    if ($UserName) {
        $loginArgs = @{
            'ServerUrl' = $ServerUrl
            'UserName'  = $UserName
        }
        if ($PSBoundParameters.ContainsKey('UserPass')) {
            $loginArgs['UserPass'] = $UserPass
        }
        $cookie = Get-QBittorrentCookie @loginArgs
        if (!$cookie) { return } # error already handled
        $headers['Cookie'] = $cookie
    }

    # Set Preferences API expects a JSON string in a form field named 'json'.
    # It ignores most (all?) invalid values.
    $url = [uri]::new($ServerUrl, 'api/v2/app/setPreferences')
    $formData = @{
        json = $preferences | ConvertTo-Json -Compress
    }

    if (!$PSCmdlet.ShouldProcess($ServerUrl)) { return }
    # Suppress remaining confirmations...
    $ConfirmPreference = 'None'

    Write-Verbose "Posting $($formData.json) to $url..."
    $resp = Invoke-WebRequest $url -Method Post -Form $formData -Headers $headers -SkipHttpErrorCheck -Verbose:$false
    if (!$resp) { return } # error already handled
    $resp.BaseResponse | Write-Verbose
    if (!$resp.BaseResponse.IsSuccessStatusCode) {
        Write-Error -Exception "Set Preferences failed: $($resp.StatusCode) - $($resp.Content)"
        return
    }

    Write-Information "qBittorrent preferences updated successfully."
}

function Update-IPFilter {
    <#
    .DESCRIPTION
        Downloads the latest IPFilter file and updates qBittorrent to use it.
    .EXAMPLE
        PS> Update-IPFilter -ServerUrl 'http://localhost:8083' -DestinationPath '~/.qBittorrent/ipfilter.dat'
        Downloads the latest IPFilter file to '~/.qBittorrent/ipfilter.dat' and updates the
        local qBittorrent server to use it.
    .EXAMPLE
        PS> Update-IPFilter -ServerUrl 'https://qbt.example.com/' -UserName 'bob' -DestinationPath '~/.qBittorrent/ipfilter.dat' -ServerPath '/data/ipfilter.dat'
        Downloads the latest IPFilter file to '~/.qBittorrent/ipfilter.dat' and updates the
        secured qBittorrent server to use it. The server is running in a container with its
        '/data' folder mapped to '~/.qBittorrent'.
    #>
    [CmdletBinding(PositionalBinding = $false, SupportsShouldProcess, ConfirmImpact = 'Low')]
    param (
        # qBittorrent server URL. Defaults to 'http://localhost:8083'.
        [uri] $ServerUrl = 'http://localhost:8083',
        # Username for the qBittorrent server.
        [string] $UserName,
        # Password for the qBittorrent server user.
        # If not specified and UserName is provided, then prompts for password.
        [string] $UserPass,
        # Path to save the downloaded IPFilter file.
        [string] $DestinationPath = './ipfilter.dat',
        # Path to the IPFilter file relative to the qBittorrent server.
        # Use this when the server is running on a different machine or in a container.
        # Defaults to DestinationPath.
        [string] $ServerPath,
        # If specified, forces update even if the IPFilter file is up to date.
        [switch] $Force
    )

    # prompt for missing inputs upfront...
    if ($UserName -and !$PSBoundParameters.ContainsKey('UserPass')) {
        $PSBoundParameters['UserPass'] = $UserPass = getQbtPassword
    }

    $InformationPreference = 'Continue'

    $ipFilter = Install-LatestIPFilter -DestinationPath $DestinationPath -Force:$Force
    if (!$ipFilter) { return } # error already handled
    if (!$ipFilter.Updated -AND !$Force) {
        return # no change
    }

    $preferencesArgs = @{
        ServerUrl    = $ServerUrl
        IPFilterPath = $ServerPath ? $ServerPath : $ipFilter.FullName
    }
    if ($UserName) {
        $preferencesArgs['UserName'] = $UserName
        $preferencesArgs['UserPass'] = $UserPass
    }

    Update-QBittorrentPreferences @preferencesArgs
}

$DefaultTaskName = 'Update qBittorrent IPFilter'

filter escapeDQ ([string]$s) { ($_ ?? $s) -replace '"', '""' }
filter escapeSQ ([string]$s) { ($_ ?? $s) -replace "'", "''" }
filter escapeArg ([string]$s) {
    # Single quote value if it contains any character with special meaning
    # in the context of a PowerShell argument value:
    # - whitespace - argument separator
    # - single/double quote - string delimiter
    # - backtick (`) - escape character or line continuation
    # - comma - argument array separator
    # - semicolon - end of statement
    # - at (@) - array/hash literal prefix, splat operator
    # - dollar ($) - variable prefix
    # - parentheses - grouping or method invocation
    # - curly braces - script block
    # - pipe (|) - pipeline, statement separator (||)
    # - ampersand (&) - background job, statement separator (&&)
    # - less/greater than (<>) - redirection, comment
    # - hash (#) - comment
    $s = $_ ?? $s
    if ($s -match '[\s''"`,;@$(){}|&<>#]') { "'" + ($s -replace "'", "''") + "'" }
    else { $s }
}

function Register-UpdateIPFilter {
    <#
    .DESCRIPTION
        Registers a Windows scheduled task to periodically update the qBittorrent IPFilter.

        Use the `Unregister-UpdateIPFilter` function to delete the task.
    .NOTES
        The server password, if any, is stored in the task definition in plain text.
        Ensure that the task is secured appropriately.
    .OUTPUTS
        When -PassThru is specified it returns the Scheduled Task object.
    .EXAMPLE
        PS> Register-UpdateIPFilter -ServerUrl 'http://localhost:8083' -DestinationPath './ipfilter.dat'
        Registers a scheduled task to update the IPFilter at the default time (Sundays at 8:00 AM).
    .EXAMPLE
        PS> Register-UpdateIPFilter -ServerUrl 'https://qbt.example.com/' -UserName 'alice' -DestinationPath './ipfilter.dat' -ServerPath '/data/ipfilter.dat' -TaskTrigger (New-ScheduledTaskTrigger -Daily -At (Get-Date '3:00 AM')) -Force
        Registers a scheduled task to update the IPFilter daily at 3:00 AM.
        If a task with the same name already exists, it is overwritten.
    #>
    [CmdletBinding(PositionalBinding = $false, SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([Microsoft.Management.Infrastructure.CimInstance])]
    param (
        # qBittorrent server URL. Defaults to 'http://localhost:8083'.
        [uri] $ServerUrl = 'http://localhost:8083',
        # Username for the qBittorrent server.
        [string] $UserName,
        # Password for the qBittorrent server user.
        # If not specified and UserName is provided, then prompts for password.
        [AllowEmptyString()]
        [string] $UserPass,
        # Path to save the downloaded IPFilter file.
        [string] $DestinationPath = './ipfilter.dat',
        # Path to the IPFilter file relative to the qBittorrent server.
        # This is useful when the server is running on a different machine or in a container.
        # Defaults to DestinationPath.
        [string] $ServerPath,

        # Name of the scheduled task to create. Defaults to 'Update qBittorrent IPFilter'.
        [string] $TaskName = $DefaultTaskName,
        # Path of the scheduled task to delete. Defaults to root path '\'.
        [string] $TaskPath = '\',
        # Trigger for the scheduled task. Defaults to weekly on Sundays at 8:00 AM.
        [object] $TaskTrigger = (New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At (Get-Date '8:00 AM')),
        [switch] $ShowTaskWindow,
        # If specified, overwrites any existing scheduled task with the same name.
        [switch] $Force,
        # If specified, returns the created Scheduled Task object.
        [switch] $PassThru
    )

    # Resolve relative paths...
    $DestinationPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($DestinationPath)

    # Prompt for missing inputs...
    if ($UserName -AND !$PSBoundParameters.ContainsKey('UserPass')) {
        $PSBoundParameters['UserPass'] = $UserPass = getQbtPassword
    }

    $scriptArgs = @(
        '-ServerUrl', (escapeArg $ServerUrl)
        if ($UserName) { '-UserName', (escapeArg $UserName) }
        if ($PSBoundParameters.ContainsKey('UserPass')) { '-UserPass', (escapeArg $UserPass) }
        '-DestinationPath', (escapeArg $DestinationPath)
        if ($ServerPath) { '-ServerPath', (escapeArg $ServerPath) }
        '-Verbose'
    )
    $script = "
        Import-Module '$PSScriptRoot/Update-IPFilter.psm1'
        Update-IPFilter $($scriptArgs -join ' ')
        "
    # convert to a single line...
    $script = ($script.Trim()) -replace '\r?\n\s*', '; '
    Write-verbose "Script: $script"

    $pwshArgs = "-NoProfile -ExecutionPolicy ByPass"
    if ($ShowTaskWindow) {
        $pwshArgs += " -NoExit"
    }
    else {
        $pwshArgs += " -WindowStyle Hidden -NonInteractive"
    }
    $pwshArgs += " -Command `"$(escapeDQ $script)`""
    $taskAction = New-ScheduledTaskAction `
        -Execute (Get-Command pwsh).Path `
        -Argument $pwshArgs `
        -WorkingDirectory $PWD

    $taskDef = New-ScheduledTask -Action $taskAction -Trigger $TaskTrigger

    if (!$PSCmdlet.ShouldProcess((Join-Path $TaskPath $TaskName), 'Register-ScheduledTask')) { return }
    $task = $taskDef | Register-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -Force:$Force -ea Stop
    if ($PassThru) { $task }
}

function Unregister-UpdateIPFilter {
    <#
    .DESCRIPTION
        Deletes the Windows scheduled task created by `Register-UpdateIPFilter`.
    #>
    [CmdletBinding(PositionalBinding = $false, SupportsShouldProcess, ConfirmImpact = 'Low')]
    param(
        # Name of the scheduled task to delete. Defaults to 'Update qBittorrent IPFilter'.
        [string] $TaskName = $DefaultTaskName,
        # Path of the scheduled task to delete. Defaults to root path '\'.
        [string] $TaskPath = '\'
    )

    Unregister-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath
}

Export-ModuleMember -Function Install-LatestIPFilter, Update-QBittorrentPreferences, Update-IPFilter, Register-UpdateIPFilter, Unregister-UpdateIPFilter, Get-QBittorrentCookie
