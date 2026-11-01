# welcome

Hardening for a fresh Debian 13 server. Run it directly on the machine you want
to harden (below), or push it to a remote from a controller
([Bootstrapping a remote server](#bootstrapping-a-remote-server)).

## Running locally

`apply.sh` configures the machine it runs on. It installs Ansible itself, so a
fresh Debian box needs nothing beyond Git and sudo access.

```bash
git clone https://github.com/cschlick/welcome
cd welcome
./apply.sh --check --diff   # dry run: report what would change
./apply.sh                  # apply
```

You do not need `-K`. The playbook needs root, and `apply.sh` works out for
itself whether sudo will ask for a password — adding `--ask-become-pass` only
when this account lacks the passwordless grant that the `accounts` role
installs. In practice that means the **first** run on a fresh box prompts for
your password (twice: once for `apt-get` installing Ansible, once as
`BECOME password:`) and every run after it prompts for neither. Passing `-K`
yourself still works and is never duplicated.

Anything after `apply.sh` passes straight through to `ansible-playbook`, so
`--tags ssh`, `--skip-tags`, and friends work as usual. The playbook always
targets this machine (`-i 'localhost,' -c local`).

Do not prefix the command with `sudo`. The script elevates only the steps that
need root, and running the whole thing as root resolves the vault password path
against root's home instead of yours.

> **`--check` is not fully read-only.** Installing Ansible and fetching the
> Galaxy collections happens before the playbook runs, regardless of the flag.
> Only the playbook itself is simulated.

### The vault password

`apply.sh` decrypts the committed `ansible/vault.yml`. It reads the password
from `~/.config/welcome/vault-password`, and prompts interactively if that file
is absent:

```bash
install -d -m 700 ~/.config/welcome
install -m 600 /dev/null ~/.config/welcome/vault-password
nano ~/.config/welcome/vault-password
```

The repository is public, so a fresh clone carries the vault ciphertext but
never the password. Keep the password in your password manager.

> **This rewrites `authorized_keys` to exactly the vaulted key.**
> `ssh_authorized_keys_exclusive` is `true` in `ansible/group_vars/all.yml`, so
> any key absent from the vault is removed. Confirm the vaulted key is one you
> hold before applying to a live host, and keep console access open:
>
> ```bash
> ansible-vault view ansible/vault.yml
> ```

### Options

All are environment variables:

```bash
WELCOME_PROFILE=desktop ./apply.sh       # apply a profile from ansible/profiles/
WELCOME_SYSTEM_HOSTNAME=vps01 ./apply.sh # set the hostname during the run
IMAGE_BUILD=1 ./apply.sh                 # build a generalized cloud-init image
```

Run interactively without `WELCOME_PROFILE` and `apply.sh` asks which profile
applies, listing whatever is in `ansible/profiles/`. There is no default on
Enter — applying the headless profile to a desktop strips its session, so the
choice is made deliberately every time. Setting `WELCOME_PROFILE` skips the
prompt, and a run with no terminal (systemd, CI, a pipe) still defaults to
`host`, which is what the detached remote path relies on.

For machine-local overrides, `apply.sh` automatically loads `ansible/local.yml`
(Git-ignored) and `/etc/welcome/local.yml` when either exists. Write them
against the variables documented in `ansible/group_vars/all.yml`.

### Results

Each run is logged to `logs/apply-<timestamp>.log`, with the most recent run
symlinked at `/var/log/ansible-apply/latest.log`. If the run leaves the system
needing a restart, it prints `REBOOT REQUIRED` along with the responsible
packages.

## Joining the mesh from the console

`bootstrap-remote.sh` prompts for an invite token, which works when you are
driving the machine over SSH from a controller. It does not help on a box you
can only reach through VNC or a physical console, where an invite token is too
long to retype and the clipboard usually does not survive the trip.

For those, put the token in the vault and let `git pull` carry it. The token
travels as ciphertext inside the repository; the only secret that has to reach
the machine by hand is the vault password, which is short enough to type.

On the controller:

```bash
ansible-vault edit ansible/vault.yml   # add: greasewood_join_token: "<token>"
git commit -am "Stage a mesh invite token" && git push
```

On the target, at the console:

```bash
git pull
./apply.sh                             # prompts for the vault password
```

The `greasewood` role joins the mesh when `greasewood_join_token` is non-empty
and the host has no `gw-*` interface yet, so re-runs never re-join. The join
task is `no_log: true`, keeping the token out of `logs/apply-*.log`.

> **This repository is public.** A committed vault is readable by anyone, and
> its history cannot be unpublished — the vault password becomes the only thing
> standing between a stranger and your mesh. Use a high-entropy vault password,
> prefer a single-use or expiring invite over a standing one, and once the host
> has joined, revoke the token and clear it from the vault so the published
> ciphertext is worthless:
>
> ```bash
> ansible-vault edit ansible/vault.yml   # set greasewood_join_token: ""
> ```

## Claude Code, Codex and Devin configuration

The `config_repos` role checks out private config repositories as the tools'
config directories, and fast-forwards them on every later run:

| Repository | Checked out as | Vault variable |
| --- | --- | --- |
| [`cschlick/claude-config`](https://github.com/cschlick/claude-config) | `~user/.claude` | `claude_config_deploy_key` |
| [`cschlick/codex-config`](https://github.com/cschlick/codex-config) | `~user/.codex` | `codex_config_deploy_key` |
| [`cschlick/devin-config`](https://github.com/cschlick/devin-config) | `~user/.config/devin` | `devin_config_deploy_key` |

It does **not** install Claude Code, Codex or Devin; do that by hand. An entry
can name a `setup` script in its repository, which runs as the account after
every sync: devin-config's `setup.sh` adds its `.gitconfig` to the global git
config, as its README asks.

The repositories are private, so each is fetched with its own GitHub deploy key held in the vault. A repository whose key is unset is skipped.
GitHub refuses the same deploy key on two repositories, so make one per repo.
One-time setup, on the controller (shown for claude-config):

```bash
ssh-keygen -t ed25519 -N '' -C welcome-claude-config -f ./deploy
# GitHub → cschlick/claude-config → Settings → Deploy keys → Add deploy key:
# paste deploy.pub, ticking "Allow write access" to push config changes from
# the machine. Not under your account's SSH keys — that would grant access to every repository.
{ echo 'claude_config_deploy_key: |'; sed 's/^/  /' deploy; }  # prints the vault entry
ansible-vault edit ansible/vault.yml   # paste it in; the | keeps the line breaks
#   claude_config_deploy_key: |
#     -----BEGIN OPENSSH PRIVATE KEY-----
#     ...
#     -----END OPENSSH PRIVATE KEY-----
shred -u ./deploy ./deploy.pub
```

To check where GitHub registered a key, `ssh -T -i <key> git@github.com`
greets a deploy key with the repository (`Hi cschlick/claude-config!`) and an
account key with just the username.

On each machine the keys land in `~/.ssh/` (`claude_config_deploy_key`,
`codex_config_deploy_key`, `devin_config_deploy_key`), and each checkout's `core.sshCommand` points at its
key, so a manual `git pull` works too — and `git push`, when the key has write
access.

> A write-enabled key in this public repository's vault lets anyone who breaks
> the vault password change that config, and its hooks and settings then run on
> every machine. Use a strong vault password.

- **Existing config directory.** If the tool has already run, the role checks
  the repository out around its runtime state (history, sessions,
  credentials). Any existing file the checkout would overwrite is moved to
  `~/.claude.pre-welcome-<timestamp>/` (or `~/.codex.…`), not deleted.
- **Local changes.** Edited tracked files or unpushed commits are left alone.
  The run reports that the checkout was not updated, and does not fail.

To sync just these: `./apply.sh --tags config_repos`.

## Bootstrapping a remote server

The remote must initially be reachable as `user` over SSH, with sudo access.

```bash
# On the controller:
brew install ansible                         # macOS
sudo apt install ansible-core openssh-client # Debian/Ubuntu

# Restore the vault password from your password manager:
install -d -m 700 ~/.config/welcome
install -m 600 /dev/null ~/.config/welcome/vault-password
nano ~/.config/welcome/vault-password

# Bootstrap the server:
./bootstrap-remote.sh user@SERVER_IP
```

Enter the server hostname when prompted, then optionally enter a Greasewood
invite token. The hostname is set before the server joins the mesh. Press Enter
at either prompt to keep the current hostname or skip joining.

After verifying Greasewood access, make SSH mesh-only and persist that setting:

```bash
./bootstrap-remote.sh user@SERVER_IP --mesh-only-ssh
```

The playbook continues locally on the server if SSH is interrupted. After
reconnecting, check its result:

```bash
ssh user@SERVER_IP 'sudo journalctl -u welcome-apply.service --no-pager'
```

The vault password stays on the controller. The server ends with SSH key-only
access for `user`; its existing password is not changed. Debian's packaged
Ghostty terminfo is also exposed system-wide as `xterm-ghostty`, so Ghostty
sessions work over SSH without a per-user `tic` command.

[ssh-workspace](https://github.com/cschlick/ssh-workspace) is installed to
`/usr/local/bin` as a client, for reaching *other* machines from this one — it
opens an SSH session attached to a persistent tmux or Screen workspace and
reconnects itself when the link drops. A host hardened by this playbook is
already a valid target for it without this, since the `packages` role installs
`screen`. Pin `ssh_workspace_ref` to a tag or commit to stop tracking upstream
`main`, or set `ssh_workspace_manage=false` to skip it.

## The desktop profile

The default `host` profile assumes nobody is sitting at the console: it
blacklists the audio, bluetooth and webcam kernel modules, strips the account
out of `audio`, `video`, `plugdev` and `netdev`, and moves networking off
NetworkManager. Applied to a machine running GNOME, that leaves a user locked
out of its own hardware on a box that may not come back on the network.

The `desktop` profile keeps every control that does not assume an empty
console:

```bash
WELCOME_PROFILE=desktop ./apply.sh               # on the machine itself
./bootstrap-remote.sh user@HOST --profile desktop # from a controller
```

It does **not** install GNOME. Install the desktop yourself (`apt install
gnome-core`, `tasksel`, …); the profile hardens around whatever is there.

It turns off the roles that would break a seated user: `module_blacklist`,
`group_prune`, `networkd` (NetworkManager owns the interfaces), `resolved`,
`disable_cups`, `disable_mdns` and `mounts` (the `noexec` `/tmp`). nftables
stays on, with 5353/udp opened so Avahi can discover printers and shares. Each
decision is commented in `ansible/profiles/desktop.yml`.

It also installs Visual Studio Code from Microsoft's apt repository
(`vscode_manage: true`), so it updates with every apply. The role stops the
`code` package from adding a second copy of that repository, which would
otherwise break `apt update` with conflicting `Signed-By` values.

VS Code runs through XWayland (`--ozone-platform=x11`), not as a native
Wayland client. Native Wayland on GNOME loses window state: maximized windows
on other workspaces come back unmaximized when you switch to them. The role
adds the flag through overrides of VS Code's launchers in
`/usr/local/share/applications/` and a `/usr/local/bin/code` wrapper, since
`~/.vscode/argv.json` cannot set it. Set `vscode_ozone_platform: ""` to go
back to native Wayland; the overrides are then removed.

No profile removes packages: the `packages` role installs and never purges.

## The router profile

> **Router profile status:** This is an untested, unfinished stub. Do not use it
> on an important router without console access, a verified backup, and careful
> review of a check-mode run.

The intended router profile preserves its firewall, interfaces, forwarding,
DNS, mounts, services, groups, and kernel modules:

```bash
./bootstrap-remote.sh user@ROUTER_IP --profile router
```
