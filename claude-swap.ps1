<#
.SYNOPSIS
    Switch the claude.ai account Claude Code uses, while every account shares the same
    config, memory, skills, settings, plugins and session history.

.DESCRIPTION
    Claude Code keeps your claude.ai login in two files:

      * .credentials.json (in ~/.claude, or in $env:CLAUDE_CONFIG_DIR when set): the
        "claudeAiOauth" tokens, "organizationUuid" and a few related entries;
      * .claude.json (in your home folder, or in $env:CLAUDE_CONFIG_DIR when set): the
        "oauthAccount" entry, a cache of the account identity.

    claude-swap keeps a copy of that login for each of your accounts, encrypted with Windows
    DPAPI, and swaps only those entries (clearing the per-account caches Claude Code rebuilds
    on its own). Everything else in both files, such as MCP server tokens, projects and
    settings, is left as it is, so all accounts run on one Claude Code setup.

    Every run first saves the live login back into its account file. Claude Code rotates
    refresh tokens when it renews them, so this keeps each saved copy current.

.PARAMETER Account
    Name (login email) or alias of the account to switch to. Without it, claude-swap moves
    to the next registered account in alphabetical order, wrapping around.

.PARAMETER New
    Registers an account by its login email. When Claude Code is logged in with that email
    right now, the live login is saved at once; otherwise the account starts empty and you
    log in the first time you switch to it.

.PARAMETER Alias
    With -New: the alias of the new account.
    Without -New: the account (name or alias) to set an alias on, followed by the alias.

.PARAMETER NewAlias
    The alias that follows "-Alias <account>". Usually given by position. Pass '' to clear
    the alias.

.PARAMETER List
    Shows the registered accounts, which one is active and whether each saved login is usable.

.PARAMETER Remove
    Deletes an account (name or alias) from claude-swap. The live Claude Code login stays.

.PARAMETER Force
    When switching: go ahead even if the live login cannot be saved first (it is discarded).
    With -Remove: skip the confirmation prompt.

.EXAMPLE
    claude-swap -New work@example.com -Alias work

    Registers the account Claude Code is logged in with right now and saves its login.

.EXAMPLE
    claude-swap -New me@example.com -Alias personal
    claude-swap personal

    Registers a second account and switches to it. Its first switch logs Claude Code out:
    start Claude Code, log in with that account, and the next claude-swap run saves it.

.EXAMPLE
    claude-swap

    Switches to the next account, alphabetical by email.

.EXAMPLE
    claude-swap -Alias me@example.com home

    Sets or replaces the alias of an existing account.

.LINK
    https://github.com/PaiCthulhu/claude-swap
#>
#Requires -Version 7.4
# (#Requires sits below the help block: above it, Get-Help stops reading the help.)
[CmdletBinding(DefaultParameterSetName = 'Switch')]
param(
    [Parameter(ParameterSetName = 'Switch', Position = 0)]
    [string] $Account,

    [Parameter(ParameterSetName = 'New', Mandatory)]
    [string] $New,

    [Parameter(ParameterSetName = 'New')]
    [Parameter(ParameterSetName = 'SetAlias', Mandatory)]
    [string] $Alias,

    [Parameter(ParameterSetName = 'SetAlias', Position = 0)]
    [AllowEmptyString()]
    [string] $NewAlias,

    [Parameter(ParameterSetName = 'List', Mandatory)]
    [switch] $List,

    [Parameter(ParameterSetName = 'Remove', Mandatory)]
    [string] $Remove,

    [Parameter(ParameterSetName = 'Switch')]
    [Parameter(ParameterSetName = 'Remove')]
    [switch] $Force
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

# What Claude Code's own logout removes, as of Claude Code 2.1.318. The credential entries
# make up a login and are saved per account. The config entries are per-account caches that
# Claude Code rebuilds on its own, so a switch clears them.
$script:CredentialKeys = @(
    'claudeAiOauth', 'organizationUuid', 'trustedDeviceToken', 'trustedDeviceEnrolledAfterRefusalAtMs',
    'enterpriseGateway', 'designOauth', 'cloudSessionsOauth'
)
$script:AccountCacheKeys = @(
    'managedSettingsNoticeSeenOrg', 'additionalModelOptionsCache', 'additionalModelOptionsAnsweredAt',
    'additionalModelCostsCache', 'modelAccessCache', 'orgModelDefaultCache', 'cachedArtifactRoster',
    'artifactRosterDenied', 'lastSeenOrgDefaultUpdatedAt', 'clientDataCache', 'clientDataCacheSlots',
    'autoCompactWindowsCache', 'cachedUsageUtilization', 'metricsStatusCache', 'metricsStatusCacheByPrincipal',
    'githubWebConnectionStatusCache', 'unusedLimitResetStatusCache', 'startupPrefetchedAt'
)
$script:Entropy = [Text.Encoding]::UTF8.GetBytes('claude-swap/v1')
$script:SchemaVersion = 1

# A note on JSON handling: Claude Code's files are edited through System.Text.Json nodes,
# which keep key case (.claude.json can hold keys that differ only in case), key order and
# the text of numbers. String values keep their content, though escapes may be written
# differently (an emoji comes out as a \u escape pair). JSON nodes are collections, and
# PowerShell unrolls collections written to the pipeline, so nodes are only ever passed as
# arguments or kept in variables and object properties, never returned from a function.

#region Helpers

function Get-ErrorMessage($ErrorRecord) {
    $exception = $ErrorRecord.Exception
    while ($exception.InnerException) { $exception = $exception.InnerException }
    $exception.Message
}

function Get-NowMs { [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }

function Format-Time($Milliseconds) {
    if ($null -eq $Milliseconds) { return '-' }
    [DateTimeOffset]::FromUnixTimeMilliseconds([long] $Milliseconds).LocalDateTime.ToString('yyyy-MM-dd HH:mm')
}

# Claude Code allows .claude.json to be a symlink: write to its target instead of replacing it.
function Get-WriteTarget([string] $Path) {
    $target = $null
    try { $target = [IO.File]::ResolveLinkTarget($Path, $true) } catch { }
    if ($target) { $target.FullName } else { $Path }
}

function Write-FileAtomic([string] $Path, [string] $Text) {
    $Path = Get-WriteTarget $Path
    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory)) { New-Item -ItemType Directory -Path $directory -Force | Out-Null }
    $temp = "$Path.$PID.tmp"
    [IO.File]::WriteAllText($temp, $Text, [Text.UTF8Encoding]::new($false))
    for ($attempt = 1; ; $attempt++) {
        try {
            [IO.File]::Move($temp, $Path, $true)
            return
        } catch {
            # Claude Code may hold the file for a moment while it writes it.
            if ($attempt -ge 20) {
                Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
                throw "Could not write ${Path}: $(Get-ErrorMessage $_)"
            }
            Start-Sleep -Milliseconds 100
        }
    }
}

#endregion

#region Claude Code file locations and storage mode

function Get-GlobalConfigPath {
    # Same rule as Claude Code: a legacy .config.json in the config folder wins when it has
    # content (or when the current file does not exist yet).
    $current = Join-Path ($env:CLAUDE_CONFIG_DIR ? $env:CLAUDE_CONFIG_DIR : $HOME) '.claude.json'
    $legacy = Join-Path $script:ConfigHome '.config.json'
    $item = Get-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
    if ($item -and -not $item.PSIsContainer -and ($item.Length -gt 0 -or -not (Test-Path -LiteralPath $current))) { return $legacy }
    $current
}

function Assert-SupportedSetup {
    if ($env:CLAUDE_CODE_CUSTOM_OAUTH_URL) {
        throw 'CLAUDE_CODE_CUSTOM_OAUTH_URL is set. claude-swap only handles the standard claude.ai login.'
    }
    # Claude Code can keep the login in Windows Credential Manager instead of the credentials
    # file: forced by an environment variable, or turned on by a feature flag it caches in its
    # config. The credentials file may then hold a stale login, so claude-swap stops here.
    $credentialManager = $env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN -eq '1'
    if (-not $credentialManager) {
        $config = Read-JsonDocument $script:GlobalConfigPath
        if ($config) {
            $features = $config.Node['cachedGrowthBookFeatures']
            if ($features -is [System.Text.Json.Nodes.JsonObject]) {
                $flag = $features['tengu_windows_credman']
                if ($null -ne $flag -and $flag.GetValueKind() -eq 'True') { $credentialManager = $true }
            }
        }
    }
    if ($credentialManager) {
        throw 'Claude Code on this machine keeps its login in Windows Credential Manager rather than in .credentials.json. claude-swap only supports the credentials file for now.'
    }
}

# Claude Code serializes its config writes with proper-lockfile: a "<config>.lock" folder that
# counts as stale after 10 seconds. Taking the same lock keeps either side from losing the
# other's write.
function Enter-ConfigLock {
    if (-not (Test-Path -LiteralPath $script:GlobalConfigPath -PathType Leaf)) { return $null }
    $lock = "$(Get-WriteTarget $script:GlobalConfigPath).lock"
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    while ($true) {
        try {
            New-Item -ItemType Directory -Path $lock -ErrorAction Stop | Out-Null
            return $lock
        } catch { }
        try {
            $age = [DateTime]::UtcNow - (Get-Item -LiteralPath $lock -Force -ErrorAction Stop).LastWriteTimeUtc
            if ($age.TotalSeconds -gt 10) { Remove-Item -LiteralPath $lock -Recurse -Force -ErrorAction SilentlyContinue }
        } catch { }
        if ([DateTime]::UtcNow -gt $deadline) {
            throw "Claude Code is busy writing $($script:GlobalConfigPath). Try again in a moment."
        }
        Start-Sleep -Milliseconds 50
    }
}

function Exit-ConfigLock($Lock) {
    if ($Lock) { Remove-Item -LiteralPath $Lock -Recurse -Force -ErrorAction SilentlyContinue }
}

#endregion

#region JSON documents

function Read-JsonDocument([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    # Claude Code rewrites some of its files in place, so a read can land on one that is empty
    # or half written. A file that exists is never taken for a missing one.
    for ($attempt = 1; ; $attempt++) {
        $problem = $null
        try {
            $text = [IO.File]::ReadAllText($Path)
            if ([string]::IsNullOrWhiteSpace($text)) {
                $problem = 'the file is empty'
            } else {
                $node = [System.Text.Json.Nodes.JsonNode]::Parse($text)
                if ($node -is [System.Text.Json.Nodes.JsonObject]) {
                    return [pscustomobject]@{ Path = $Path; Node = $node; Indented = $text.Contains("`n"); Text = $text }
                }
                $problem = 'it does not hold a JSON object'
            }
        } catch {
            $problem = Get-ErrorMessage $_
        }
        if ($attempt -ge 10) { throw "Could not read ${Path}: $problem" }
        Start-Sleep -Milliseconds 50
    }
}

function New-JsonDocument([string] $Path, [bool] $Indented) {
    $node = [System.Text.Json.Nodes.JsonNode]::Parse('{}')
    [pscustomobject]@{ Path = $Path; Node = $node; Indented = $Indented; Text = $null }
}

function ConvertTo-JsonText($Document) {
    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $Document.Indented
    $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    # .NET indents with CRLF on Windows while Claude Code writes LF. Raw line breaks only
    # appear between tokens (inside strings they are escaped), so the replace is safe.
    try {
        $Document.Node.ToJsonString($options) -replace "`r`n", "`n"
    } catch {
        throw "Could not rewrite $($Document.Path): $(Get-ErrorMessage $_). Nothing was changed."
    }
}

function Get-JsonString($Object, [string] $Key) {
    if ($Object -isnot [System.Text.Json.Nodes.JsonObject]) { return $null }
    $value = $Object[$Key]
    if ($null -eq $value -or $value.GetValueKind() -ne 'String') { return $null }
    $value.GetValue[string]()
}

function Get-JsonInt64($Object, [string] $Key) {
    if ($Object -isnot [System.Text.Json.Nodes.JsonObject]) { return $null }
    $value = $Object[$Key]
    if ($null -eq $value -or $value.GetValueKind() -ne 'Number') { return $null }
    try { $value.GetValue[long]() } catch { $null }
}

function Set-JsonProperty($Object, [string] $Key, $Value) {
    if ($null -eq $Value) {
        [void] $Object.Remove($Key)
    } else {
        $Object[$Key] = $Value.DeepClone()
    }
}

#endregion

#region Encryption

function Protect-Text([string] $Text) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sealed = [System.Security.Cryptography.ProtectedData]::Protect($bytes, $script:Entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    [Convert]::ToBase64String($sealed)
}

function Unprotect-Text([string] $Base64) {
    try {
        $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($Base64), $script:Entropy, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    } catch {
        throw 'A saved login could not be decrypted. Saved logins only open for the Windows user, on the machine, that saved them.'
    }
    [Text.Encoding]::UTF8.GetString($bytes)
}

#endregion

#region Accounts

function ConvertTo-AccountKey([string] $Name) { $Name.Trim().ToLowerInvariant() }

function Get-AccountPath([string] $Name) { Join-Path $script:AccountsDir "$(ConvertTo-AccountKey $Name).json" }

function Read-Account([string] $Path) {
    $document = Read-JsonDocument $Path
    if (-not $document) { return $null }
    $node = $document.Node
    [pscustomobject]@{
        Path                  = $Path
        Name                  = [string] (Get-JsonString $node 'name')
        Alias                 = [string] (Get-JsonString $node 'alias')
        CreatedAt             = Get-JsonInt64 $node 'createdAt'
        SavedAt               = Get-JsonInt64 $node 'savedAt'
        Plan                  = [string] (Get-JsonString $node 'plan')
        RateLimitTier         = [string] (Get-JsonString $node 'rateLimitTier')
        RefreshTokenExpiresAt = Get-JsonInt64 $node 'refreshTokenExpiresAt'
        Login                 = [string] (Get-JsonString $node 'login')
    }
}

function Save-Account($Account) {
    $record = [ordered] @{
        schema                = $script:SchemaVersion
        name                  = $Account.Name
        alias                 = if ($Account.Alias) { $Account.Alias } else { $null }
        createdAt             = $Account.CreatedAt
        savedAt               = $Account.SavedAt
        plan                  = if ($Account.Plan) { $Account.Plan } else { $null }
        rateLimitTier         = if ($Account.RateLimitTier) { $Account.RateLimitTier } else { $null }
        refreshTokenExpiresAt = $Account.RefreshTokenExpiresAt
        login                 = if ($Account.Login) { $Account.Login } else { $null }
    }
    Write-FileAtomic -Path $Account.Path -Text (($record | ConvertTo-Json) -replace "`r`n", "`n")
}

function New-Account([string] $Name, [string] $Alias) {
    [pscustomobject]@{
        Path                  = Get-AccountPath $Name
        Name                  = ConvertTo-AccountKey $Name
        Alias                 = $Alias
        CreatedAt             = Get-NowMs
        SavedAt               = $null
        Plan                  = ''
        RateLimitTier         = ''
        RefreshTokenExpiresAt = $null
        Login                 = ''
    }
}

function Get-Accounts {
    if (-not (Test-Path -LiteralPath $script:AccountsDir)) { return }
    $accounts = foreach ($file in Get-ChildItem -LiteralPath $script:AccountsDir -Filter '*.json' -File) {
        $account = $null
        try { $account = Read-Account $file.FullName } catch { }
        if ($account -and $account.Name) { $account }
        else { Write-Warning "Skipping $($file.Name): it is not a valid claude-swap account file." }
    }
    $accounts | Sort-Object Name
}

function Resolve-Account([string] $Reference, $Accounts) {
    $key = $Reference.Trim()
    $found = @($Accounts | Where-Object { $_.Name -eq $key -or ($_.Alias -and $_.Alias -eq $key) })
    if ($found.Count -eq 0) {
        $known = @($Accounts | ForEach-Object { Format-Account $_ }) -join ', '
        if (-not $known) { $known = 'none yet' }
        throw "No account named '$Reference'. Registered: $known."
    }
    $found[0]
}

function Assert-AliasAvailable([string] $Alias, $Accounts, [string] $Owner) {
    if ($Alias -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
        throw "Alias '$Alias' is not valid: use letters, digits, '.', '_' or '-', starting with a letter or digit."
    }
    foreach ($other in $Accounts) {
        if ($other.Name -ne $Owner -and $other.Alias -eq $Alias) { throw "Alias '$Alias' already belongs to $($other.Name)." }
    }
}

function Format-Account($Account) {
    if ($Account.Alias) { "$($Account.Alias) <$($Account.Name)>" } else { $Account.Name }
}

function Format-Plan([string] $Plan, [string] $RateLimitTier) {
    if (-not $Plan) { return '-' }
    if ($RateLimitTier -match '_(\d+x)$') { "$Plan $($Matches[1])" } else { $Plan }
}

function Get-LoginStatus($Account) {
    if (-not $Account.Login) { return 'empty' }
    try { [void] (Unprotect-Text $Account.Login) } catch { return 'unreadable' }
    if ($null -ne $Account.RefreshTokenExpiresAt -and $Account.RefreshTokenExpiresAt -le (Get-NowMs)) { return 'expired' }
    'ok'
}

function Get-SavedRefreshToken($Account) {
    if (-not $Account.Login) { return $null }
    try {
        $payload = [System.Text.Json.Nodes.JsonNode]::Parse((Unprotect-Text $Account.Login))
        Get-JsonString $payload['claudeAiOauth'] 'refreshToken'
    } catch {
        $null
    }
}

function Get-LastSelected {
    $state = $null
    try { $state = Read-JsonDocument $script:StatePath } catch { return $null }
    if ($state) { Get-JsonString $state.Node 'lastSelected' }
}

function Set-LastSelected([string] $Name) {
    Write-FileAtomic -Path $script:StatePath -Text ((@{ lastSelected = $Name } | ConvertTo-Json) -replace "`r`n", "`n")
}

#endregion

#region Live login (what Claude Code is using now)

function Get-LiveLogin($Credentials, $Config) {
    $oauth = $null
    $organization = $null
    $identity = $null
    if ($Credentials) {
        $oauth = $Credentials.Node['claudeAiOauth']
        $organization = $Credentials.Node['organizationUuid']
    }
    if ($Config) { $identity = $Config.Node['oauthAccount'] }

    $live = [pscustomobject]@{
        LoggedIn              = $oauth -is [System.Text.Json.Nodes.JsonObject]
        Email                 = Get-JsonString $identity 'emailAddress'
        Consistent            = $true
        RefreshToken          = Get-JsonString $oauth 'refreshToken'
        Plan                  = [string] (Get-JsonString $oauth 'subscriptionType')
        RateLimitTier         = [string] (Get-JsonString $oauth 'rateLimitTier')
        RefreshTokenExpiresAt = Get-JsonInt64 $oauth 'refreshTokenExpiresAt'
        Payload               = ''
    }
    if (-not $live.LoggedIn) { return $live }

    # The login (.credentials.json) and the cached identity (.claude.json) must describe the
    # same account, or the email cannot be trusted to say whose tokens these are.
    $loginOrganization = $null
    if ($null -ne $organization -and $organization.GetValueKind() -eq 'String') { $loginOrganization = $organization.GetValue[string]() }
    $identityOrganization = Get-JsonString $identity 'organizationUuid'
    if ($loginOrganization -and $identityOrganization -and $loginOrganization -ne $identityOrganization) { $live.Consistent = $false }

    $payload = [System.Text.Json.Nodes.JsonNode]::Parse('{}')
    foreach ($key in $script:CredentialKeys) {
        $value = $Credentials.Node[$key]
        if ($null -ne $value) { Set-JsonProperty $payload $key $value }
    }
    if ($null -ne $identity) { Set-JsonProperty $payload 'oauthAccount' $identity }
    $live.Payload = $payload.ToJsonString()
    $live
}

function Read-LiveLogin { Get-LiveLogin (Read-JsonDocument $script:CredentialsPath) (Read-JsonDocument $script:GlobalConfigPath) }

function Save-AccountLogin($Account, $Live) {
    $Account.Login = Protect-Text $Live.Payload
    $Account.Plan = $Live.Plan
    $Account.RateLimitTier = $Live.RateLimitTier
    $Account.RefreshTokenExpiresAt = $Live.RefreshTokenExpiresAt
    $Account.SavedAt = Get-NowMs
    Save-Account $Account
}

# Works out whose login Claude Code holds and, when it belongs to a registered account,
# stores it there. Runs at the start of every command.
function Sync-LiveLogin {
    $live = Read-LiveLogin
    $sync = [pscustomobject]@{ State = 'LoggedOut'; Email = $live.Email; Account = $null; Other = $null; LivePayload = $live.Payload; LivePlan = (Format-Plan $live.Plan $live.RateLimitTier) }
    if (-not $live.LoggedIn) { return $sync }
    if (-not $live.Email) { $sync.State = 'Unknown'; return $sync }
    if (-not $live.Consistent) { $sync.State = 'Inconsistent'; return $sync }

    $key = ConvertTo-AccountKey $live.Email
    $accounts = @(Get-Accounts)

    # A session left open during a swap can write its old login back over the new one. If its
    # tokens match another account's saved copy, they are not stored under this account.
    if ($live.RefreshToken) {
        foreach ($other in $accounts) {
            if ($other.Name -eq $key) { continue }
            if ((Get-SavedRefreshToken $other) -ceq $live.RefreshToken) {
                $sync.State = 'Conflict'
                $sync.Other = $other
                return $sync
            }
        }
    }

    $account = $accounts | Where-Object { $_.Name -eq $key } | Select-Object -First 1
    if (-not $account) { $sync.State = 'Unregistered'; return $sync }
    $sync.State = 'Registered'
    $sync.Account = $account

    if ($account.Login) {
        $saved = $null
        try { $saved = Unprotect-Text $account.Login } catch {
            Write-Warning "The saved login of $(Format-Account $account) could not be decrypted; replacing it with the live login."
        }
        if ($null -ne $saved -and $saved -ceq $live.Payload) { return $sync }
        # Renewed tokens are expected, but a different plan means these tokens probably belong
        # to another account (a session that renewed its own login after a swap).
        if ($null -ne $saved -and (
                ($account.Plan -and $live.Plan -and $account.Plan -ne $live.Plan) -or
                ($account.RateLimitTier -and $live.RateLimitTier -and $account.RateLimitTier -ne $live.RateLimitTier))) {
            $sync.State = 'PlanChanged'
            return $sync
        }
    }
    Save-AccountLogin -Account $account -Live $live
    $sync
}

# Writes a saved login into Claude Code's files, or logs Claude Code out locally (without
# revoking anything on the server) when -PayloadJson is empty. -ExpectedLive is the live
# login the caller based its decision on: if Claude Code changed it since, nothing is written.
function Write-LiveLogin([string] $PayloadJson, [string] $ExpectedLive) {
    $payload = $null
    if ($PayloadJson) { $payload = [System.Text.Json.Nodes.JsonNode]::Parse($PayloadJson) }

    $lock = Enter-ConfigLock
    try {
        $credentials = Read-JsonDocument $script:CredentialsPath
        $config = Read-JsonDocument $script:GlobalConfigPath
        if ((Get-LiveLogin $credentials $config).Payload -cne $ExpectedLive) {
            throw 'Claude Code changed its login while claude-swap was switching. Nothing was changed; run claude-swap again.'
        }
        if (-not $credentials) { $credentials = New-JsonDocument $script:CredentialsPath $false }
        if (-not $config) { $config = New-JsonDocument $script:GlobalConfigPath $true }

        foreach ($key in $script:CredentialKeys) {
            $value = $null
            if ($null -ne $payload) { $value = $payload[$key] }
            Set-JsonProperty $credentials.Node $key $value
        }
        $identity = $null
        if ($null -ne $payload) { $identity = $payload['oauthAccount'] }
        Set-JsonProperty $config.Node 'oauthAccount' $identity
        foreach ($key in $script:AccountCacheKeys) { [void] $config.Node.Remove($key) }

        # Both files are rendered before either is written, and the first is put back if the
        # second cannot be written, so a failure never leaves half a switch behind.
        $credentialsText = ConvertTo-JsonText $credentials
        $configText = ConvertTo-JsonText $config
        Write-FileAtomic $credentials.Path $credentialsText
        try {
            Write-FileAtomic $config.Path $configText
        } catch {
            if ($null -ne $credentials.Text) { Write-FileAtomic $credentials.Path $credentials.Text }
            else { Remove-Item -LiteralPath $credentials.Path -Force -ErrorAction SilentlyContinue }
            throw
        }
    } finally {
        Exit-ConfigLock $lock
    }
}

function Assert-CanLeave($Sync, [bool] $Force) {
    if ($Force) { return }
    $openSession = 'A Claude Code session left open during a swap can cause this by writing its own login back.'
    switch ($Sync.State) {
        'Unregistered' {
            throw "Claude Code is logged in as $($Sync.Email), which is not registered, so switching away would lose that login. Register it first with 'claude-swap -New $($Sync.Email)', or pass -Force to discard it."
        }
        'Unknown' {
            throw "Claude Code holds a login without a cached account identity (oauthAccount in .claude.json), so claude-swap cannot tell whose login it is. Start Claude Code once and try again, or pass -Force to discard that login."
        }
        'Inconsistent' {
            throw "The login in .credentials.json and the account cached in .claude.json belong to different organizations. $openSession Close every session and try again, or pass -Force to discard the live login."
        }
        'Conflict' {
            throw "Claude Code says it is logged in as $($Sync.Email) but holds the saved login of $($Sync.Other.Name). $openSession Close every session and try again, or pass -Force to discard the live login."
        }
        'PlanChanged' {
            $account = $Sync.Account
            $register = if ($account.Alias) { "claude-swap -New $($account.Name) -Alias $($account.Alias)" } else { "claude-swap -New $($account.Name)" }
            throw "Claude Code says it is logged in as $($account.Name), but the live login is on plan '$($Sync.LivePlan)' while the saved one is '$(Format-Plan $account.Plan $account.RateLimitTier)'. $openSession Close every session and try again, or pass -Force to discard the live login. If the plan really changed, register the account again: claude-swap -Remove $($account.Name) -Force, then $register"
        }
    }
}

function Get-SessionCount {
    # The Claude desktop app also runs a claude.exe; it is installed under WindowsApps or
    # AnthropicClaude and keeps its own login, so it is left out. npm installs run on node.
    $native = @(Get-Process -Name 'claude' -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and $_.Path -notmatch '\\WindowsApps\\|\\AnthropicClaude\\' })
    $npm = @()
    try {
        $npm = @(Get-CimInstance -ClassName Win32_Process -Filter "Name = 'node.exe'" -ErrorAction Stop |
            Where-Object { $_.CommandLine -match '@anthropic-ai[\\/]claude-code' })
    } catch { }
    $native.Count + $npm.Count
}

function Write-SessionWarning {
    $count = Get-SessionCount
    if ($count -gt 0) {
        Write-Warning ("{0} Claude Code process(es) still running. Open sessions keep the previous login in memory and may write it back when they renew it: exit them and start again (claude --continue resumes the conversation)." -f $count)
    }
}

function Write-LiveState($Sync, $Accounts) {
    switch ($Sync.State) {
        'LoggedOut' {
            $pending = Get-LastSelected
            if ($pending -and @($Accounts | Where-Object { $_.Name -eq $pending }).Count -gt 0) {
                Write-Host "Claude Code is logged out. Log in as $pending to finish switching to it." -ForegroundColor Yellow
            } else {
                Write-Host 'Claude Code is logged out.' -ForegroundColor Yellow
            }
        }
        'Unregistered' { Write-Host "Claude Code is logged in as $($Sync.Email), which is not registered. Save it with: claude-swap -New $($Sync.Email)" -ForegroundColor Yellow }
        'Unknown' { Write-Warning 'Claude Code holds a login without a cached account identity; start Claude Code once so it refreshes it.' }
        'Inconsistent' { Write-Warning 'The live login and the cached account identity disagree; close every Claude Code session and run claude-swap again.' }
        'Conflict' { Write-Warning "Claude Code says it is $($Sync.Email) but holds the saved login of $($Sync.Other.Name); close every Claude Code session and run claude-swap again." }
        'PlanChanged' { Write-Warning "The live login of $($Sync.Account.Name) is on plan '$($Sync.LivePlan)', unlike its saved login; it was not saved. Run a switch to see what to do." }
    }
}

#endregion

#region Commands

function Invoke-Switch([string] $Reference, [bool] $Force) {
    $sync = Sync-LiveLogin
    $accounts = @(Get-Accounts)
    if ($accounts.Count -eq 0) {
        throw 'No accounts registered yet. Register the one Claude Code is logged in with: claude-swap -New <email>'
    }

    if ($Reference) {
        $target = Resolve-Account $Reference $accounts
    } else {
        if ($accounts.Count -lt 2) {
            throw "Only $($accounts[0].Name) is registered. Add another account with: claude-swap -New <email>"
        }
        $current = if ($sync.Account) { $sync.Account.Name } else { Get-LastSelected }
        $index = -1
        for ($i = 0; $i -lt $accounts.Count; $i++) {
            if ($accounts[$i].Name -eq $current) { $index = $i; break }
        }
        $target = $accounts[($index + 1) % $accounts.Count]
    }

    Assert-CanLeave $sync $Force
    if ($sync.State -eq 'Registered' -and $sync.Account.Name -eq $target.Name) {
        Write-Host "Already using $(Format-Account $target)."
        return
    }

    $previous = if ($sync.Account) { Format-Account $sync.Account } elseif ($sync.Email) { $sync.Email } else { 'logged out' }
    $status = Get-LoginStatus $target
    if ($status -ne 'ok') {
        Write-LiveLogin -PayloadJson '' -ExpectedLive $sync.LivePayload
        Set-LastSelected $target.Name
        $reason = switch ($status) {
            'empty' { 'has no saved login yet' }
            'expired' { "has a saved login that expired on $(Format-Time $target.RefreshTokenExpiresAt)" }
            default { 'has a saved login that cannot be decrypted (it was saved by another Windows user or on another machine)' }
        }
        Write-Warning "$(Format-Account $target) $reason."
        Write-Host "Claude Code is now logged out (was $previous). Start Claude Code, log in as $($target.Name), and the next claude-swap run saves that login." -ForegroundColor Yellow
        Write-SessionWarning
        return
    }

    Write-LiveLogin -PayloadJson (Unprotect-Text $target.Login) -ExpectedLive $sync.LivePayload
    Set-LastSelected $target.Name
    Write-Host "Switched to $(Format-Account $target) [$(Format-Plan $target.Plan $target.RateLimitTier)] (was $previous)." -ForegroundColor Green
    Write-SessionWarning
}

function Invoke-New([string] $Name, [string] $Alias) {
    $key = ConvertTo-AccountKey $Name
    if ($key -notmatch '^[^@\s\\/:*?"<>|]+@[^@\s\\/:*?"<>|]+$') {
        throw "'$Name' is not a login email. Name each account after the email you sign in to claude.ai with."
    }
    $sync = Sync-LiveLogin
    $accounts = @(Get-Accounts)
    if (@($accounts | Where-Object { $_.Name -eq $key }).Count -gt 0) { throw "$key is already registered." }
    $Alias = $Alias.Trim()
    if ($Alias) { Assert-AliasAvailable $Alias $accounts '' }

    $account = New-Account $key $Alias
    if ($sync.State -eq 'Unregistered' -and (ConvertTo-AccountKey $sync.Email) -eq $key) {
        Save-AccountLogin -Account $account -Live (Read-LiveLogin)
        Set-LastSelected $key
        Write-Host "Registered $(Format-Account $account) and saved the login Claude Code is using now." -ForegroundColor Green
    } else {
        Save-Account $account
        $handle = if ($Alias) { $Alias } else { $key }
        Write-Host "Registered $(Format-Account $account) with no saved login yet." -ForegroundColor Green
        Write-Host "Switch to it with 'claude-swap $handle' and log in once when Claude Code asks."
    }
}

function Invoke-SetAlias([string] $Reference, [string] $NewAlias) {
    [void] (Sync-LiveLogin)
    $accounts = @(Get-Accounts)
    $account = Resolve-Account $Reference $accounts
    $NewAlias = $NewAlias.Trim()
    if ($NewAlias) { Assert-AliasAvailable $NewAlias $accounts $account.Name }
    $account.Alias = $NewAlias
    Save-Account $account
    if ($NewAlias) { Write-Host "$($account.Name) is now aliased '$NewAlias'." -ForegroundColor Green }
    else { Write-Host "Cleared the alias of $($account.Name)." -ForegroundColor Green }
}

function Invoke-List {
    $sync = Sync-LiveLogin
    $accounts = @(Get-Accounts)
    if ($accounts.Count -eq 0) {
        Write-Host 'No accounts registered yet. Register the one Claude Code is logged in with: claude-swap -New <email>'
    } else {
        $rows = foreach ($account in $accounts) {
            $login = switch (Get-LoginStatus $account) {
                'empty' { 'not saved yet' }
                'expired' { "expired $(Format-Time $account.RefreshTokenExpiresAt)" }
                'unreadable' { 'cannot be decrypted' }
                default { if ($null -ne $account.RefreshTokenExpiresAt) { "ok until $(Format-Time $account.RefreshTokenExpiresAt)" } else { 'ok' } }
            }
            [pscustomobject]@{
                Active  = if ($sync.State -eq 'Registered' -and $sync.Account.Name -eq $account.Name) { '*' } else { '' }
                Account = $account.Name
                Alias   = $account.Alias
                Plan    = Format-Plan $account.Plan $account.RateLimitTier
                Login   = $login
                Saved   = Format-Time $account.SavedAt
            }
        }
        Write-Host (($rows | Format-Table -AutoSize | Out-String).TrimEnd())
        Write-Host ''
    }
    Write-LiveState $sync $accounts
}

function Invoke-Remove([string] $Reference, [bool] $Force) {
    [void] (Sync-LiveLogin)
    $accounts = @(Get-Accounts)
    $account = Resolve-Account $Reference $accounts
    if (-not $Force -and -not $PSCmdlet.ShouldContinue("Delete the saved login of $(Format-Account $account)? The live Claude Code login is not touched.", 'claude-swap')) {
        return
    }
    Remove-Item -LiteralPath $account.Path -Force
    if ((Get-LastSelected) -eq $account.Name) { Remove-Item -LiteralPath $script:StatePath -Force -ErrorAction SilentlyContinue }
    Write-Host "Removed $(Format-Account $account)." -ForegroundColor Green
}

#endregion

try {
    if (-not $IsWindows) {
        throw 'claude-swap runs on Windows only: it encrypts saved logins with DPAPI and expects Claude Code to keep its login in .credentials.json (on macOS it lives in the Keychain).'
    }
    $script:ConfigHome = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $HOME '.claude' }
    $script:CredentialsPath = Join-Path $script:ConfigHome '.credentials.json'
    $script:GlobalConfigPath = Get-GlobalConfigPath
    $script:StoreDir = if ($env:CLAUDE_SWAP_HOME) { $env:CLAUDE_SWAP_HOME } else { Join-Path $env:LOCALAPPDATA 'claude-swap' }
    $script:AccountsDir = Join-Path $script:StoreDir 'accounts'
    $script:StatePath = Join-Path $script:StoreDir 'state.json'
    Assert-SupportedSetup
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData

    switch ($PSCmdlet.ParameterSetName) {
        'Switch' { Invoke-Switch -Reference $Account -Force $Force.IsPresent }
        'New' { Invoke-New -Name $New -Alias $Alias }
        'SetAlias' {
            if (-not $PSBoundParameters.ContainsKey('NewAlias')) {
                throw "Give the alias after the account: claude-swap -Alias <account> <alias> ('' clears it)."
            }
            Invoke-SetAlias -Reference $Alias -NewAlias $NewAlias
        }
        'List' { Invoke-List }
        'Remove' { Invoke-Remove -Reference $Remove -Force $Force.IsPresent }
    }
} catch {
    # Expected failures (our own throw statements) are reported as one plain line; anything
    # else is a bug and keeps its full error record, script line included.
    $exception = $_.Exception
    if ($exception -is [System.Management.Automation.RuntimeException] -and $exception.WasThrownFromThrowStatement) {
        $record = [System.Management.Automation.ErrorRecord]::new([Exception]::new($exception.Message), 'ClaudeSwap', 'InvalidOperation', $null)
        $PSCmdlet.ThrowTerminatingError($record)
    }
    throw
}
