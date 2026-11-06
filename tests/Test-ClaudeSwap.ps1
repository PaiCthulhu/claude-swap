#Requires -Version 7.4
<#
.SYNOPSIS
    Self-contained tests for claude-swap.

.DESCRIPTION
    Builds a throwaway fake Claude Code setup in a temp folder (through CLAUDE_CONFIG_DIR and
    CLAUDE_SWAP_HOME) and runs claude-swap against it. Your real Claude Code files and saved
    accounts are never read or written. Exits with code 1 when any check fails.

.EXAMPLE
    pwsh -File tests/Test-ClaudeSwap.ps1
#>
Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Security.Cryptography.ProtectedData

$Swap = (Resolve-Path (Join-Path $PSScriptRoot '..' 'claude-swap.ps1')).Path
$Root = Join-Path ([IO.Path]::GetTempPath()) "claude-swap-tests-$([guid]::NewGuid().ToString('N'))"
$ClaudeDir = Join-Path $Root 'claude'
$StoreDir = Join-Path $Root 'store'
$CredentialsPath = Join-Path $ClaudeDir '.credentials.json'
$ConfigPath = Join-Path $ClaudeDir '.claude.json'
$Hour = 3600000
$Day = 24 * $Hour
$Now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()

$script:Passed = 0
$script:Failed = 0
$script:Output = ''
$script:Warnings = ''

#region Test helpers

function Section([string] $Title) { Write-Host "`n$Title" -ForegroundColor Cyan }

function Assert([bool] $Condition, [string] $Message) {
    if ($Condition) { $script:Passed++; Write-Host "  ok    $Message" -ForegroundColor DarkGreen }
    else { $script:Failed++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}

function Assert-Throws([scriptblock] $Block, [string] $Pattern, [string] $Message) {
    try {
        & $Block
        Assert $false "$Message (nothing was thrown)"
    } catch {
        $text = $_.Exception.Message
        Assert ($text -match $Pattern) $Message
        if ($text -notmatch $Pattern) { Write-Host "        got: $text" -ForegroundColor DarkYellow }
    }
}

# Runs claude-swap and keeps its host output and warnings for the following assertions.
function Invoke-Swap {
    $warnings = $null
    $script:Output = (& $Swap @args -WarningVariable warnings -WarningAction SilentlyContinue 6>&1 | Out-String)
    $script:Warnings = (@($warnings) | ForEach-Object { "$_" }) -join "`n"
}

# The leading comma keeps PowerShell from unrolling the returned JsonObject into its entries.
function Read-Node([string] $Path) { , [System.Text.Json.Nodes.JsonNode]::Parse([IO.File]::ReadAllText($Path)) }

function Write-Node($Node, [string] $Path, [bool] $Indented) {
    $options = [System.Text.Json.JsonSerializerOptions]::new()
    $options.WriteIndented = $Indented
    $options.Encoder = [System.Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping
    [IO.File]::WriteAllText($Path, ($Node.ToJsonString($options) -replace "`r`n", "`n"))
}

function ConvertTo-Node($Value) { , [System.Text.Json.Nodes.JsonNode]::Parse(($Value | ConvertTo-Json -Depth 10 -Compress)) }

function New-OAuth([string] $Id, [string] $Refresh, [long] $RefreshExpires, [string] $Tier = 'default_claude_max_20x') {
    [ordered] @{
        accessToken            = "$Id-access"
        refreshToken           = $Refresh
        expiresAt              = $Now + $Hour
        refreshTokenExpiresAt  = $RefreshExpires
        scopes                 = @('user:inference', 'user:profile')
        subscriptionType       = 'max'
        subscriptionTypeSource = 'sign_in'
        rateLimitTier          = $Tier
    }
}

# Simulates Claude Code finishing a login (or renewing tokens) for an account.
function Set-FakeLogin([string] $Email, [string] $Organization, $OAuth) {
    $credentials = Read-Node $CredentialsPath
    $credentials['claudeAiOauth'] = ConvertTo-Node $OAuth
    $credentials['organizationUuid'] = ConvertTo-Node $Organization
    Write-Node $credentials $CredentialsPath $false

    $config = Read-Node $ConfigPath
    $config['oauthAccount'] = ConvertTo-Node ([ordered] @{
            accountUuid      = "uuid-$Organization"
            emailAddress     = $Email
            organizationUuid = $Organization
            accountCreatedAt = '2025-01-01T00:00:00.000Z'
            displayName      = 'Tester'
        })
    Write-Node $config $ConfigPath $true
}

# Simulates an open session writing only the token block back.
function Set-FakeTokens($OAuth) {
    $credentials = Read-Node $CredentialsPath
    $credentials['claudeAiOauth'] = ConvertTo-Node $OAuth
    Write-Node $credentials $CredentialsPath $false
}

function Set-FakeOrganization([string] $Organization) {
    $credentials = Read-Node $CredentialsPath
    $credentials['organizationUuid'] = ConvertTo-Node $Organization
    Write-Node $credentials $CredentialsPath $false
}

function Get-Live {
    $credentials = Read-Node $CredentialsPath
    $config = Read-Node $ConfigPath
    $oauth = $credentials['claudeAiOauth']
    $identity = $config['oauthAccount']
    [pscustomobject]@{
        Refresh  = if ($null -ne $oauth) { $oauth['refreshToken'].GetValue[string]() } else { $null }
        Org      = if ($null -ne $credentials['organizationUuid']) { $credentials['organizationUuid'].GetValue[string]() } else { $null }
        Email    = if ($null -ne $identity) { $identity['emailAddress'].GetValue[string]() } else { $null }
        Device   = if ($null -ne $credentials['trustedDeviceToken']) { $credentials['trustedDeviceToken'].GetValue[string]() } else { $null }
        Caches   = @('modelAccessCache', 'cachedUsageUtilization' | Where-Object { $null -ne $config[$_] }).Count
        Mcp      = $credentials['mcpOAuth'].ToJsonString()
    }
}

function Get-AccountRecord([string] $Email) {
    $path = Join-Path $StoreDir 'accounts' "$Email.json"
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
}

function Get-SavedRefresh([string] $Email) {
    $record = Get-AccountRecord $Email
    if (-not $record -or -not $record.login) { return $null }
    $bytes = [System.Security.Cryptography.ProtectedData]::Unprotect([Convert]::FromBase64String($record.login), [Text.Encoding]::UTF8.GetBytes('claude-swap/v1'), 'CurrentUser')
    $payload = [System.Text.Json.Nodes.JsonNode]::Parse([Text.Encoding]::UTF8.GetString($bytes))
    $payload['claudeAiOauth']['refreshToken'].GetValue[string]()
}

function Test-SameExceptIdentity([string] $Left, [string] $Right) {
    $a = [System.Text.Json.Nodes.JsonNode]::Parse($Left)
    $b = [System.Text.Json.Nodes.JsonNode]::Parse($Right)
    # oauthAccount is swapped and the per-account caches are cleared; the rest must be equal.
    foreach ($key in 'oauthAccount', 'modelAccessCache', 'cachedUsageUtilization') {
        [void] $a.Remove($key)
        [void] $b.Remove($key)
    }
    [System.Text.Json.Nodes.JsonNode]::DeepEquals($a, $b)
}

#endregion

$saved = @{
    CLAUDE_CONFIG_DIR                  = $env:CLAUDE_CONFIG_DIR
    CLAUDE_SWAP_HOME                   = $env:CLAUDE_SWAP_HOME
    CLAUDE_CODE_FORCE_WINDOWS_CREDMAN  = $env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN
    CLAUDE_CODE_CUSTOM_OAUTH_URL       = $env:CLAUDE_CODE_CUSTOM_OAUTH_URL
}
try {
    New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
    $env:CLAUDE_CONFIG_DIR = $ClaudeDir
    $env:CLAUDE_SWAP_HOME = $StoreDir
    $env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN = $null
    $env:CLAUDE_CODE_CUSTOM_OAUTH_URL = $null

    # Fixture: account A is logged in. The config carries what a naive JSON round-trip breaks:
    # keys differing only in case, non-ASCII text, date-like strings, number formatting.
    $oauthA = New-OAuth 'a' 'a-refresh-1' ($Now + 10 * $Day)
    $credentialsFixture = [ordered] @{
        mcpOAuth         = [ordered] @{ 'Server|abc123' = [ordered] @{ serverName = 'Server'; accessToken = 'mcp-secret'; expiresAt = 123 } }
        claudeAiOauth      = $oauthA
        organizationUuid   = 'org-a'
        trustedDeviceToken = 'td-a'
    }
    [IO.File]::WriteAllText($CredentialsPath, ($credentialsFixture | ConvertTo-Json -Depth 10 -Compress))
    $configFixture = @'
{
  "numStartups": 42,
  "ratio": 1.50,
  "tipsHistory": {
    "configuração": 3
  },
  "projects": {
    "F:/Proj": {
      "allowedTools": [],
      "lastCost": 0.000123
    },
    "f:/Proj": {
      "allowedTools": [
        "Bash"
      ],
      "lastSessionId": "x"
    }
  },
  "oauthAccount": {
    "accountUuid": "uuid-org-a",
    "emailAddress": "a@example.com",
    "organizationUuid": "org-a",
    "accountCreatedAt": "2025-01-01T00:00:00.000Z",
    "displayName": "Ana"
  },
  "emptyObject": {},
  "modelAccessCache": {
    "claude-x": true
  },
  "cachedUsageUtilization": 0.5,
  "lastSeen": "2026-11-06T12:34:56.789Z"
}
'@ -replace "`r`n", "`n"
    [IO.File]::WriteAllText($ConfigPath, $configFixture)
    $mcpFixture = (Get-Live).Mcp

    Section 'Register the account Claude Code is logged in with'
    Invoke-Swap -New a@example.com -Alias work
    $recordA = Get-AccountRecord 'a@example.com'
    Assert ($null -ne $recordA) 'account file is created'
    Assert ([bool] $recordA.login) 'the live login is saved right away'
    Assert ((Get-SavedRefresh 'a@example.com') -eq 'a-refresh-1') 'the saved login holds the live tokens'
    Assert (-not ((Get-Content (Join-Path $StoreDir 'accounts' 'a@example.com.json') -Raw) -match 'a-refresh-1|a-access')) 'tokens are not stored in plain text'
    Assert ($recordA.alias -eq 'work' -and $recordA.plan -eq 'max') 'alias and plan are recorded'

    Section 'Register an account that is not logged in'
    Invoke-Swap -New B@Example.com -Alias personal
    $recordB = Get-AccountRecord 'b@example.com'
    Assert ($null -ne $recordB -and $recordB.name -eq 'b@example.com') 'account is created with a lower-case name'
    Assert (-not $recordB.login) 'it starts without a login'

    Section 'Validation'
    Assert-Throws { Invoke-Swap -New 'not-an-email' } 'not a login email' 'names must be login emails'
    Assert-Throws { Invoke-Swap -New a@example.com } 'already registered' 'an email registers only once'
    Assert-Throws { Invoke-Swap -New c@example.com -Alias WORK } 'already belongs' 'aliases are unique, ignoring case'
    Assert-Throws { Invoke-Swap -New c@example.com -Alias 'bad alias' } 'not valid' 'aliases are single words'
    Assert-Throws { Invoke-Swap nobody } "No account named 'nobody'" 'unknown accounts are reported'

    Section 'Switching to an account without a login logs Claude Code out'
    $configBefore = [IO.File]::ReadAllText($ConfigPath)
    Invoke-Swap personal
    $live = Get-Live
    Assert ($null -eq $live.Refresh -and $null -eq $live.Org) 'claudeAiOauth and organizationUuid are removed'
    Assert ($null -eq $live.Email) 'oauthAccount is removed'
    Assert ($null -eq $live.Device) 'the other login entries (trustedDeviceToken) are removed'
    Assert ($live.Caches -eq 0) 'per-account caches in .claude.json are cleared'
    Assert ($live.Mcp -eq $mcpFixture) 'MCP server tokens are untouched'
    Assert (Test-SameExceptIdentity $configBefore ([IO.File]::ReadAllText($ConfigPath))) 'the rest of .claude.json is untouched'
    Assert ($script:Warnings -match 'no saved login yet') 'the user is told to log in'
    Invoke-Swap -List
    Assert ($script:Output -match 'Log in as b@example.com') 'the list says which login is pending'

    Section 'Logging in, then switching back with no argument'
    Set-FakeLogin 'b@example.com' 'org-b' (New-OAuth 'b' 'b-refresh-1' ($Now + 5 * $Day) 'default_claude_max_5x')
    Invoke-Swap
    $live = Get-Live
    Assert ((Get-SavedRefresh 'b@example.com') -eq 'b-refresh-1') 'the new login is saved to its account first'
    Assert ($live.Refresh -eq 'a-refresh-1' -and $live.Org -eq 'org-a' -and $live.Email -eq 'a@example.com') 'cycling wraps around to the first account'
    Assert ($live.Mcp -eq $mcpFixture) 'MCP server tokens are still untouched'
    Assert ($script:Output -match 'Switched to work <a@example.com> \[max 20x\]') 'the switch is reported with the plan'

    Section 'Renewed tokens are saved before leaving an account'
    Set-FakeTokens (New-OAuth 'a2' 'a-refresh-2' ($Now + 10 * $Day))
    Invoke-Swap personal
    Assert ((Get-Live).Refresh -eq 'b-refresh-1') 'switches to the named account'
    Assert ((Get-SavedRefresh 'a@example.com') -eq 'a-refresh-2') 'the rotated token is what got saved'
    Assert ($null -eq (Get-Live).Device) "an entry the target login lacks is removed"
    Invoke-Swap work
    Assert ((Get-Live).Refresh -eq 'a-refresh-2') 'switching back restores the rotated token'
    Assert ((Get-Live).Device -eq 'td-a') 'and the other login entries of that account'
    Invoke-Swap WORK
    Assert ($script:Output -match 'Already using') 'switching to the active account is a no-op (alias match ignores case)'

    Section 'An unregistered login is never thrown away silently'
    Set-FakeLogin 'c@example.com' 'org-c' (New-OAuth 'c' 'c-refresh-1' ($Now + 10 * $Day))
    Assert-Throws { Invoke-Swap personal } 'not registered' 'switching away from it is refused'
    Assert ((Get-Live).Refresh -eq 'c-refresh-1') 'the refused switch changed nothing'
    Invoke-Swap -New c@example.com
    Assert ((Get-SavedRefresh 'c@example.com') -eq 'c-refresh-1') 'registering it saves it'
    Invoke-Swap
    Assert ((Get-Live).Email -eq 'a@example.com') 'with three accounts, c wraps around to a'
    Invoke-Swap
    Assert ((Get-Live).Email -eq 'b@example.com') 'then a moves on to b'
    Invoke-Swap -Remove c@example.com -Force
    Assert ($null -eq (Get-AccountRecord 'c@example.com')) '-Remove deletes the account file'
    Set-FakeLogin 'd@example.com' 'org-d' (New-OAuth 'd' 'd-refresh-1' ($Now + 10 * $Day))
    Invoke-Swap personal -Force
    Assert ((Get-Live).Email -eq 'b@example.com') '-Force switches anyway'

    Section 'A session that writes an old login back is caught'
    Set-FakeTokens (New-OAuth 'a2' 'a-refresh-2' ($Now + 10 * $Day))
    Assert-Throws { Invoke-Swap work } 'holds the saved login of a@example.com' 'the mismatch is reported'
    Assert ((Get-SavedRefresh 'b@example.com') -eq 'b-refresh-1') "account b keeps its own saved login"
    Invoke-Swap work -Force
    Assert ((Get-Live).Email -eq 'a@example.com') '-Force recovers'
    Set-FakeOrganization 'org-x'
    Assert-Throws { Invoke-Swap personal } 'different organizations' 'a login and identity from different organizations are refused'
    Set-FakeOrganization 'org-a'

    Section 'Expired logins'
    Invoke-Swap personal
    Set-FakeTokens (New-OAuth 'b2' 'b-refresh-2' ($Now - $Day) 'default_claude_max_5x')
    Invoke-Swap work
    Invoke-Swap -List
    Assert ($script:Output -match 'expired') 'the list flags the expired login'
    Invoke-Swap personal
    Assert ($script:Warnings -match 'expired on') 'switching to it warns that it expired'
    Assert ($null -eq (Get-Live).Refresh) 'and logs Claude Code out so the user can log in again'
    Invoke-Swap
    Assert ((Get-Live).Email -eq 'a@example.com') 'cycling while logged out continues from the pending account'

    Section 'Saved logins that cannot be decrypted'
    $recordPath = Join-Path $StoreDir 'accounts' 'b@example.com.json'
    $record = Get-Content -LiteralPath $recordPath -Raw | ConvertFrom-Json
    $record.login = [Convert]::ToBase64String([byte[]](1..64))
    [IO.File]::WriteAllText($recordPath, ($record | ConvertTo-Json))
    Invoke-Swap -List
    Assert ($script:Output -match 'cannot be decrypted') 'the list flags it instead of failing'
    Invoke-Swap personal
    Assert ($script:Warnings -match 'cannot be decrypted') 'switching to it says why it is unusable'
    Assert ($null -eq (Get-Live).Refresh) 'and logs Claude Code out so the user can log in again'
    Set-FakeLogin 'b@example.com' 'org-b' (New-OAuth 'b3' 'b-refresh-3' ($Now + 5 * $Day) 'default_claude_max_5x')
    Invoke-Swap -List
    Assert ($script:Warnings -match 'could not be decrypted; replacing it') 'logging in again replaces the unreadable copy, with a warning'
    Assert ((Get-SavedRefresh 'b@example.com') -eq 'b-refresh-3') 'the fresh login is saved'

    Section 'A different plan under the same email is not saved'
    Set-FakeTokens (New-OAuth 'x' 'x-refresh-1' ($Now + 5 * $Day) 'default_claude_max_20x')
    Assert-Throws { Invoke-Swap work } "plan 'max 20x'" 'the mismatch is reported'
    Assert ((Get-SavedRefresh 'b@example.com') -eq 'b-refresh-3') 'account b keeps its saved login'
    Invoke-Swap work -Force
    Assert ((Get-Live).Email -eq 'a@example.com') '-Force switches away and discards it'

    Section 'Writes never leave half a switch behind'
    $credentialsBefore = [IO.File]::ReadAllText($CredentialsPath)
    $configGood = [IO.File]::ReadAllText($ConfigPath)
    [IO.File]::WriteAllText($ConfigPath, ($configGood -replace '"numStartups": 42', '"numStartups": 42, "broken": "\ud83d"'))
    Assert-Throws { Invoke-Swap personal } 'Nothing was changed' 'a .claude.json that cannot be rewritten stops the switch'
    Assert ([IO.File]::ReadAllText($CredentialsPath) -ceq $credentialsBefore) '.credentials.json was not touched'
    [IO.File]::WriteAllText($ConfigPath, $configGood)
    [IO.File]::WriteAllText($CredentialsPath, '')
    Assert-Throws { Invoke-Swap -List } 'file is empty' 'an empty .credentials.json is an error, not a missing login'
    Assert ([IO.File]::ReadAllText($CredentialsPath) -eq '') 'and it is left alone'
    [IO.File]::WriteAllText($CredentialsPath, $credentialsBefore)

    Section 'Credential Manager storage is refused'
    $config = Read-Node $ConfigPath
    $config['cachedGrowthBookFeatures'] = ConvertTo-Node ([ordered] @{ tengu_windows_credman = $true })
    Write-Node $config $ConfigPath $true
    Assert-Throws { Invoke-Swap -List } 'Credential Manager' 'the feature flag cached in .claude.json is honored'
    $config['cachedGrowthBookFeatures'] = ConvertTo-Node ([ordered] @{ tengu_windows_credman = $false })
    Write-Node $config $ConfigPath $true
    Invoke-Swap -List
    Assert ($script:Output -match 'a@example.com') 'a false flag is fine'
    [void] $config.Remove('cachedGrowthBookFeatures')
    Write-Node $config $ConfigPath $true
    $env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN = '1'
    Assert-Throws { Invoke-Swap -List } 'Credential Manager' 'so is CLAUDE_CODE_FORCE_WINDOWS_CREDMAN'
    $env:CLAUDE_CODE_FORCE_WINDOWS_CREDMAN = $null
    $legacy = Join-Path $ClaudeDir '.config.json'
    [IO.File]::WriteAllText($legacy, '{"cachedGrowthBookFeatures":{"tengu_windows_credman":true}}')
    Assert-Throws { Invoke-Swap -List } 'Credential Manager' 'a legacy .config.json takes the place of .claude.json, as in Claude Code'
    Remove-Item -LiteralPath $legacy

    Section 'The config lock Claude Code uses is honored'
    $lock = "$ConfigPath.lock"
    New-Item -ItemType Directory -Path $lock | Out-Null
    (Get-Item -LiteralPath $lock).LastWriteTime = (Get-Date).AddMinutes(-1)
    Invoke-Swap personal
    Assert ((Get-Live).Email -eq 'b@example.com' -and -not (Test-Path -LiteralPath $lock)) 'a stale lock is taken over and released'
    New-Item -ItemType Directory -Path $lock | Out-Null
    Assert-Throws { Invoke-Swap work } 'busy writing' 'a fresh lock held by someone else is waited on, not broken'
    Assert ((Get-Live).Email -eq 'b@example.com') 'and nothing was switched'
    Remove-Item -LiteralPath $lock
    Invoke-Swap work
    Assert ((Get-Live).Email -eq 'a@example.com') 'once it is released the switch goes through'

    Section 'Removing the pending account'
    Invoke-Swap -New e@example.com
    Invoke-Swap e@example.com
    Invoke-Swap -Remove e@example.com -Force
    Invoke-Swap -List
    Assert ($script:Output -match 'logged out' -and $script:Output -notmatch 'Log in as e@example.com') 'the list no longer points at it'
    Invoke-Swap work
    Assert ((Get-Live).Email -eq 'a@example.com') 'switching back works from the logged-out state'

    Section 'Aliases'
    Assert-Throws { Invoke-Swap -Alias work } 'Give the alias after the account' '-Alias without a value explains the syntax'
    Invoke-Swap -Alias work job
    Assert ((Get-AccountRecord 'a@example.com').alias -eq 'job') '-Alias <alias> <new> renames an alias'
    Invoke-Swap job
    Assert ($script:Output -match 'Already using job') 'the new alias resolves'
    Invoke-Swap -Alias a@example.com ''
    Assert ($null -eq (Get-AccountRecord 'a@example.com').alias) "-Alias <name> '' clears it"
    Assert-Throws { Invoke-Swap -Alias a@example.com personal } 'already belongs' 'an alias in use is refused'
    Invoke-Swap -Alias a@example.com work

    Section 'A symlinked .claude.json stays a symlink'
    $dotfiles = Join-Path $Root 'dotfiles'
    New-Item -ItemType Directory -Path $dotfiles | Out-Null
    $realConfig = Join-Path $dotfiles 'claude.json'
    Move-Item -LiteralPath $ConfigPath -Destination $realConfig
    $linked = $false
    try { New-Item -ItemType SymbolicLink -Path $ConfigPath -Target $realConfig -ErrorAction Stop | Out-Null; $linked = $true } catch { }
    if ($linked) {
        Invoke-Swap personal
        Invoke-Swap work
        Assert ((Get-Item -LiteralPath $ConfigPath).LinkType -eq 'SymbolicLink') 'the link is kept'
        Assert ((Get-Live).Email -eq 'a@example.com') 'and the switch went through it'
        Assert (-not (Test-Path -LiteralPath "$realConfig.lock")) 'the lock next to the real file is released'
    } else {
        Move-Item -LiteralPath $realConfig -Destination $ConfigPath
        Write-Host '  skip  creating symlinks needs Developer Mode or an elevated shell' -ForegroundColor DarkYellow
    }

    Section 'File fidelity'
    $configText = [IO.File]::ReadAllText($ConfigPath)
    $configBytes = [IO.File]::ReadAllBytes($ConfigPath)
    Assert (Test-SameExceptIdentity $configFixture $configText) '.claude.json matches the original apart from oauthAccount and the account caches'
    Assert ($configText.Contains('"F:/Proj"') -and $configText.Contains('"f:/Proj"')) 'keys that differ only in case both survive'
    Assert ($configText.Contains('"configuração"')) 'non-ASCII text is not escaped'
    Assert ($configText.Contains('"ratio": 1.50')) 'number text is kept as written'
    Assert ($configText.Contains('"2026-11-06T12:34:56.789Z"')) 'date-like strings are kept as written'
    Assert (-not $configText.Contains("`r")) 'line endings stay LF'
    Assert (-not ($configBytes[0] -eq 0xEF -and $configBytes[1] -eq 0xBB)) 'no byte order mark is added'
    Assert (-not [IO.File]::ReadAllText($CredentialsPath).Contains("`n")) '.credentials.json stays compact'
    Assert ((Get-Live).Mcp -eq $mcpFixture) 'MCP server tokens survived every swap'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($script:Failed -gt 0) {
    Write-Host "$script:Failed failed, $script:Passed passed." -ForegroundColor Red
    exit 1
}
Write-Host "All $script:Passed checks passed." -ForegroundColor Green
