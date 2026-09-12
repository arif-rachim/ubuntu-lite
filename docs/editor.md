# Editor: Helix + ruff + biome

The image ships **Helix** (`hx`) instead of VS Code: one 20 MB binary, LSP,
tree-sitter, multi-cursor and fuzzy pickers built in, no plugins, no Electron.
`Super+c` opens it in a terminal; `hx .` opens the current project.

Language tooling on the image, all static binaries in `/usr/local/bin`:

| Tool | Languages | Role in Helix |
|---|---|---|
| `ruff` | Python | language server (diagnostics, code actions, imports) and formatter, on save |
| `biome` | JS, TS, TSX, JSON, CSS | language server (lint, quick fixes) and formatter, on save |

Configured in `~/.config/helix/languages.toml`; `~/.config/helix/config.toml`
holds the theme and keys (`Ctrl+S` save, `Ctrl+Q` quit, relative numbers).

## Ten-minute Helix

Helix is modal like Vim but "select first, then act": `w` selects a word,
`d` deletes the selection. Run `hx --tutor` once.

| Keys | Action |
|---|---|
| `i` / `Esc` | insert / back to normal |
| `Space f` | file picker (fuzzy) |
| `Space b` | buffer picker |
| `Space /` | grep in project |
| `Space s` / `Space S` | symbols in file / workspace (LSP) |
| `Space a` | code action (ruff/biome fixes) |
| `Space k` | hover docs |
| `gd` / `gr` | go to definition / references |
| `Space d` | diagnostics picker |
| `Ctrl+w v` / `Ctrl+w s` | split vertical / horizontal |
| `:fmt` | format (also on save) |
| `:sh cmd` / `:run-shell-command` | run a shell command |
| `Ctrl+o` / `Ctrl+i` | jump back / forward |
| `x` then `d` | select line, delete |
| `%` | select whole file |
| `u` / `U` | undo / redo |

## TypeScript type information

biome gives lint, formatting and quick fixes but not type checking. Type
errors, completions with types and rename come from
`typescript-language-server`, which needs Node. Node lives in your dev
container, so run Helix from inside it:

```bash
# in the project's container image (Dockerfile) once:
RUN npm install -g typescript typescript-language-server

# then, on the host:
docker compose exec app sh -c 'hx .'        # if hx is installed in the image
```

Or keep editing on the host and add to the project's `.helix/languages.toml`:

```toml
[language-server.typescript-language-server]
command = "docker"
args = ["compose", "exec", "-T", "app", "typescript-language-server", "--stdio"]

[[language]]
name = "typescript"
language-servers = ["typescript-language-server", "biome"]
```

This runs the language server inside the container over stdio while Helix
stays on the host. Paths must match between host and container (mount the
project at the same path, e.g. `-v $PWD:$PWD -w $PWD`).

For Python, `ruff` covers lint and formatting; type checking (`pyright`,
`basedpyright`, `ty`) can be run the same way from the container.

## Going back to VS Code

Add `code` to `config/packages/gui.txt`, set `BUNDLE_VSCODE_EXTENSIONS=1`
in `config/build.env`, rebuild. Nothing else changes.
