# welcome

Hardening for a fresh Debian 13 server. The remote must initially be reachable
as `user` over SSH, with sudo access.

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

The playbook continues locally on the server if SSH is interrupted. After
reconnecting, check its result:

```bash
ssh user@SERVER_IP 'sudo journalctl -u welcome-apply.service --no-pager'
```

The vault password stays on the controller. The server ends with SSH key-only
access for `user`; its existing password is not changed.
