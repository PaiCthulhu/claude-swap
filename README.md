# claude-swap

Switch the claude.ai account [Claude Code](https://code.claude.com) uses, without splitting
your setup in two.

If you have two Claude subscriptions (say, work and personal), the usual advice is to give each
account its own `CLAUDE_CONFIG_DIR`. That splits everything: memory, skills, `CLAUDE.md`,
settings, plugins, MCP servers and session history now live twice and drift apart.

claude-swap keeps **one** Claude Code setup and swaps only the login. Same car, different
fuel tank.

```text
PS> claude-swap -List

Active Account          Alias    Plan    Login                     Saved
------ -------          -----    ----    -----                     -----
       me@example.com   personal max 5x  ok until 2026-11-15 01:03 2026-11-06 01:03
*      work@example.com work     max 20x ok until 2026-11-15 01:03 2026-11-06 01:03

PS> claude-swap
Switched to personal <me@example.com> [max 5x] (was work <work@example.com>).
```

## How it works

On Windows, Claude Code keeps your claude.ai login in two files:

| File | Entries that make up the login |
|---|---|
| `~/.claude/.credentials.json` | `claudeAiOauth` (access and refresh tokens, plan), `organizationUuid` and a few related entries such as `trustedDeviceToken` |
| `~/.claude.json` | `oauthAccount` (cached identity: email, organization) |

claude-swap saves those entries once per account. On a switch it writes back **only those
entries**, the same set Claude Code's own logout removes, and clears the per-account caches in
`.claude.json` (model access, usage and similar) that Claude Code rebuilds by itself.
Everything else in both files is left alone. That includes the OAuth tokens of your MCP
servers, which share `.credentials.json` with the login.

- **Saved logins are encrypted** with Windows DPAPI (current user scope), one file per account
  in `%LOCALAPPDATA%\claude-swap\accounts\`.
- **Every run saves the live login first.** Claude Code rotates refresh tokens when it renews
  them, so a copy saved last week is stale. Before doing anything else, claude-swap stores the
  current tokens in the active account's file.
- **The active account is recognized** by the email cached in `oauthAccount`, cross-checked
  against the organization of the login itself.
- **A switch is all or nothing.** Both files are rendered before either is written, and the
  first is restored if the second can't be saved. claude-swap also takes the lock Claude Code
  uses for `.claude.json`, so neither side overwrites the other's changes.
- **It never makes network calls.** Nothing leaves your machine.

## Requirements

- Windows 10 or 11.
- [PowerShell 7.4+](https://learn.microsoft.com/powershell/scripting/install/installing-powershell-on-windows):
  `winget install Microsoft.PowerShell`. Windows PowerShell 5.1 can't run it: its JSON
  parser can't read `.claude.json` files that hold keys differing only in case.
- Claude Code signed in with a claude.ai subscription (Pro, Max, Team, Enterprise). API keys,
  Bedrock, Vertex and `CLAUDE_CODE_OAUTH_TOKEN` logins don't go through these files, so
  claude-swap has nothing to swap for them.
- The login has to live in `.credentials.json`. Claude Code is gradually moving Windows
  logins to Windows Credential Manager, through a server-side feature flag it caches in
  `.claude.json`, or when `CLAUDE_CODE_FORCE_WINDOWS_CREDMAN=1` is set. If your install has
  moved, claude-swap detects it and stops: the credentials file may then hold a stale copy.
- macOS and Linux aren't supported. macOS keeps the login in the Keychain, and DPAPI is
  Windows-only.

## Install

```powershell
git clone https://github.com/PaiCthulhu/claude-swap.git
cd claude-swap

# Put the folder on your user PATH, then open a new terminal.
$dir = (Get-Location).Path
[Environment]::SetEnvironmentVariable('Path', [Environment]::GetEnvironmentVariable('Path', 'User') + ";$dir", 'User')
```

After that, `claude-swap` works from PowerShell, and from `cmd.exe` through `claude-swap.cmd`.
If you downloaded a ZIP instead of cloning, run `Get-ChildItem -Recurse | Unblock-File` in the
folder first.

## First-time setup

1. With Claude Code logged in to your first account, register it. This saves the current
   login:

   ```powershell
   claude-swap -New work@example.com -Alias work
   ```

2. Register the second account. It starts empty:

   ```powershell
   claude-swap -New me@example.com -Alias personal
   ```

3. Switch to it. Since there's no saved login yet, Claude Code is logged out. This only
   happens locally: nothing is revoked on the server.

   ```powershell
   claude-swap personal
   ```

4. Start `claude` and log in with the second account.

5. Run any claude-swap command, such as `claude-swap -List`. It notices the new login and
   saves it. From now on, `claude-swap` flips between the two accounts with no browser
   involved.

## Usage

| Command | What it does |
|---|---|
| `claude-swap` | Switch to the next account, alphabetical by email, wrapping around |
| `claude-swap <email or alias>` | Switch to that account |
| `claude-swap -New <email>` | Register an account (saves the live login if it is that account) |
| `claude-swap -New <email> -Alias <alias>` | Register an account with an alias |
| `claude-swap -Alias <email or alias> <new alias>` | Set or replace an alias (`''` clears it) |
| `claude-swap -List` | Show accounts, the active one and whether each saved login is usable |
| `claude-swap -Remove <email or alias>` | Forget an account (add `-Force` to skip the prompt) |
| `Get-Help claude-swap -Full` | Full help |

Accounts are named by the email you sign in to claude.ai with. That's how claude-swap knows
which saved login the live one belongs to. Aliases are optional short names.

## Switching safely

- **Exit your Claude Code sessions before switching**, then start again. `claude --continue`
  or `/resume` picks the conversation back up, since history is shared. An open session keeps
  the old login in memory and may write it back to disk when it renews its token.
  claude-swap warns you when Claude Code processes are running (native or npm installs; the
  desktop app is left out).
- **A login that can't be saved is never discarded silently.** claude-swap refuses to switch
  in four cases unless you pass `-Force`:
  - the live login belongs to an unregistered email;
  - the login and the cached identity disagree;
  - the live tokens match another account's saved copy, a sign that an open session wrote an
    old login back;
  - the live login is on a different plan than the account's saved one, the sign of a session
    that renewed its own login after a swap. If the plan really changed, register the
    account again: `claude-swap -Remove <email> -Force`, then `claude-swap -New <email>`.
- **Expired logins are flagged.** Each saved login records when its refresh token expires.
  Switching to an expired account logs Claude Code out so you can log in again, and the next
  run saves the fresh login. Logins that can't be decrypted get the same treatment. A login
  revoked on the server (for example after "log out of all devices") can't be detected
  offline: Claude Code just asks you to log in, and claude-swap picks the new login up.

## What doesn't follow the switch

Some things live on Anthropic's servers, per account, so they change when the account
changes:

- claude.ai connectors (the integrations you connect on claude.ai)
- usage limits and extra usage
- Remote Control and web sessions

Anything else on your machine that borrows Claude Code's login file (some agent tools do) will
follow the switch too.

## Switch history

Every switch appends one line to `history.jsonl` in the claude-swap folder, so other tools (a
usage dashboard, say) can tell which account was in use at a given moment:

```json
{"t":1793985718169,"from":"work@example.com","to":"me@example.com","loggedOut":false}
```

- `t` is the moment of the switch, in milliseconds since the Unix epoch (UTC).
- `from` is the account that was logged in, or `null` if Claude Code was logged out.
- `loggedOut` is `true` when the target had no usable saved login, so Claude Code was left
  logged out and you log in as `to` next.
- Running claude-swap for the account already in use records nothing.
- Lines older than 90 days are dropped whenever a new line is written.
- If the file can't be written, claude-swap prints a warning and the switch still goes through.

## Configuration

| Variable | Effect |
|---|---|
| `CLAUDE_CONFIG_DIR` | Respected the way Claude Code does it: both files are read from that folder (a legacy `.config.json` there wins, as in Claude Code) |
| `CLAUDE_SWAP_HOME` | Where claude-swap keeps its account files (default `%LOCALAPPDATA%\claude-swap`) |

## Security notes

- DPAPI ties each saved login to your Windows user on this machine. Account files can't be
  copied to another PC or user and opened there.
- Any program running as you can decrypt them. The same is true of `.credentials.json`
  itself, which Claude Code stores in plain text.
- To remove everything, delete `%LOCALAPPDATA%\claude-swap`.

## Tests

```powershell
pwsh -File tests/Test-ClaudeSwap.ps1
```

The tests build a throwaway fake Claude Code setup in a temp folder and never touch your real
files or accounts.

## Disclaimer

claude-swap is an unofficial tool, not affiliated with Anthropic. It relies on how Claude Code
lays out its files, and that can change with any release. It was tested with Claude Code
2.1.318 on Windows 11 and PowerShell 7.6. The supported way to run several accounts is
[`CLAUDE_CONFIG_DIR`](https://code.claude.com/docs/en/authentication). Use only accounts you're
entitled to, under Anthropic's terms for each subscription.

## License

[MIT](LICENSE)
