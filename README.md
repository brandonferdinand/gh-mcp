# gh-mcp

A tiny **Model Context Protocol** server that wraps the GitHub CLI (`gh`). It reuses whatever account `gh` is already logged into on your machine — **no PAT to manage, no token to store**.

Useful when you want an MCP-speaking client (Claude Desktop, Claude Code, Cursor, etc.) to act on GitHub *as you*, without provisioning a separate fine-grained token.

## Why

The official GitHub MCP servers want a Personal Access Token. If you already use `gh auth login` (with SSO, device flow, keyring storage, etc.), this server piggybacks on that and avoids a second secret to rotate.

## Features

- **Three tools, broad coverage**:
  - `gh_run` — passthrough for any `gh` subcommand (e.g. `gh pr list`, `gh repo view`)
  - `gh_api` — structured access to the REST and GraphQL APIs via `gh api`
  - `gh_whoami` — quick `gh auth status` for sanity checks
- **Zero runtime dependencies** beyond `bash`, `jq`, and `gh`
- **Optional allowlist** (`GH_MCP_ALLOWLIST`) to restrict which subcommands the server will run
- **JSON-RPC 2.0 over stdio**, MCP protocol version `2024-11-05`
- **Selftest** built in: `./gh-mcp.sh --selftest` exercises the protocol end-to-end with a stub `gh`

## Requirements

- macOS or Linux with **bash 4+**
- [`gh`](https://cli.github.com/) installed and authenticated. Check with `gh auth status`.
- `jq` on PATH. Install with `brew install jq` or `apt install jq`.

## Install

```sh
# 1. Drop the script somewhere stable
curl -fsSL https://raw.githubusercontent.com/brandonferdinand/gh-mcp/main/gh-mcp.sh \
  -o ~/bin/gh-mcp.sh
chmod +x ~/bin/gh-mcp.sh

# 2. Verify it runs
~/bin/gh-mcp.sh --version
~/bin/gh-mcp.sh --selftest
```

## Configure an MCP client

### Claude Desktop

Edit `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows) and merge in:

```json
{
  "mcpServers": {
    "github": {
      "command": "/Users/YOUR_USER/bin/gh-mcp.sh",
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
      }
    }
  }
}
```

The `env.PATH` matters on macOS — Claude Desktop launches MCP servers without your login shell, so `gh` and `jq` won't be found unless they're on this PATH. Run `which gh && which jq` to confirm the right directories.

Fully quit and relaunch Claude Desktop. You should see `github` show up in the MCP indicator.

### Claude Code

```sh
claude mcp add github /Users/YOUR_USER/bin/gh-mcp.sh
```

## Usage

The server exposes three tools. Examples of the JSON payloads an MCP client will send:

| Tool | Example arguments | Effect |
| --- | --- | --- |
| `gh_whoami` | `{}` | `gh auth status` |
| `gh_run` | `{"args":["repo","list","--limit","5"]}` | `gh repo list --limit 5` |
| `gh_run` | `{"args":["pr","view","123","--json","title,state,reviews"]}` | View a PR as JSON |
| `gh_run` | `{"args":["pr","list"],"cwd":"/path/to/repo"}` | List PRs inside a local clone |
| `gh_api` | `{"endpoint":"/user"}` | `gh api /user` |
| `gh_api` | `{"endpoint":"/repos/{owner}/{repo}/issues","method":"POST","raw_fields":{"title":"Bug","body":"..."}}` | Create an issue |
| `gh_api` | `{"endpoint":"graphql","fields":{"query":"query { viewer { login } }"}}` | GraphQL query |
| `gh_api` | `{"endpoint":"/repos/{owner}/{repo}/issues","query_params":{"state":"open"},"paginate":true}` | All open issues, paginated |

`gh_api` is preferred over `gh_run api ...` because it gives the model a structured contract for endpoints, methods, fields, and pagination instead of asking it to remember `gh api` flag syntax.

## Security

This server runs with the full permissions of your local `gh` auth. By default it will let the MCP client invoke **any** `gh` subcommand, including destructive ones (`gh repo delete`, `gh secret set`, `gh release delete`, …).

### Restrict what the server can do

Set `GH_MCP_ALLOWLIST` to a comma-separated list of top-level subcommands you want to permit. Any call to a subcommand not in the list is refused before `gh` is invoked.

```json
{
  "mcpServers": {
    "github": {
      "command": "/Users/YOUR_USER/bin/gh-mcp.sh",
      "env": {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
        "GH_MCP_ALLOWLIST": "repo,pr,issue,api,auth,search,workflow,run"
      }
    }
  }
}
```

Recommended baseline if you want read-mostly access: `"repo,pr,issue,api,auth,search"`.

### Threat model

- **Local-only**: the server runs as a child process of your MCP client, on your machine. It does not open any network ports.
- **Auth is yours**: tokens live wherever `gh` keeps them (keyring, `~/.config/gh/...`). The server never reads token bytes — it just executes `gh`.
- **No prompts**: a few `gh` commands prompt interactively (e.g. `gh auth login`). Those will hang under MCP; prefer flag-driven invocations.

## Troubleshooting

- **Server doesn't appear in Claude Desktop**: check the app's MCP log (Help → View Logs in Claude Desktop). The server logs to stderr with a `[gh-mcp]` prefix.
- **`gh not found on PATH`**: add `env.PATH` to your client config (see above).
- **`jq not found on PATH`**: `brew install jq` or `apt install jq`.
- **A call hangs**: probably an interactive `gh` prompt. Re-issue with flags that fully specify the action (`--yes`, `--title`, `--body`, etc.).
- **Debug logging**: set `GH_MCP_LOG_LEVEL=debug` in the client `env` to log each incoming request.

## Development

```sh
./gh-mcp.sh --version       # print version
./gh-mcp.sh --help          # print usage
./gh-mcp.sh --selftest      # run protocol smoke test against a stub gh
```

To manually drive the server, pipe JSON-RPC into it:

```sh
printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"gh_whoami","arguments":{}}}' \
  | ./gh-mcp.sh
```

## License

MIT — see [LICENSE](./LICENSE).
