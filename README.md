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
./apply.sh -K --check --diff   # dry run: report what would change
./apply.sh -K                  # apply
```

`-K` prompts for your sudo password. It is required on the **first** run: the
playbook needs root, and the `accounts` role is what grants this account
passwordless sudo in the first place. Without `-K` the run fails with
`sudo: a password is required`, because Ansible invokes sudo non-interactively.
Once a full run has completed, `-K` is no longer needed.

Expect two password prompts on that first run — one from `apt-get` installing
Ansible, and the `BECOME password:` prompt from the playbook itself.

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
WELCOME_PROFILE=router ./apply.sh        # apply a profile from ansible/profiles/
WELCOME_SYSTEM_HOSTNAME=vps01 ./apply.sh # set the hostname during the run
IMAGE_BUILD=1 ./apply.sh                 # build a generalized cloud-init image
```

For machine-local overrides, `apply.sh` automatically loads `ansible/local.yml`
(Git-ignored) and `/etc/welcome/local.yml` when either exists. Write them
against the variables documented in `ansible/group_vars/all.yml`.

### Results

Each run is logged to `logs/apply-<timestamp>.log`, with the most recent run
symlinked at `/var/log/ansible-apply/latest.log`. If the run leaves the system
needing a restart, it prints `REBOOT REQUIRED` along with the responsible
packages.

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

## The router profile

> **Router profile status:** This is an untested, unfinished stub. Do not use it
> on an important router without console access, a verified backup, and careful
> review of a check-mode run.

The intended router profile preserves its firewall, interfaces, forwarding,
DNS, mounts, services, groups, and kernel modules:

```bash
./bootstrap-remote.sh user@ROUTER_IP --profile router
```
