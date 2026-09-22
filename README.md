# jlx-cloud

jlx-cloud prepares Ubuntu cloud machines and then delegates user-level package
and shell configuration to a pinned [dot-jay](https://github.com/annaduraij/dot-jay)
revision.

The boundary is intentional:

- jlx-cloud owns OS updates, SSH hardening, firewall policy, unattended upgrades,
  provider checks, swap, sysctl settings, and the provisioning lifecycle.
- dot-jay owns Linux package selection, shell configuration, Git preferences, and
  SSH client configuration for the login user.

## Modes

The default mode applies dot-jay's `jlx-cloud` profile. Its Linux package set is
`sudo`, `zsh`, `git`, `curl`, and `tmux`.

Add `--host` to apply `jlx-cloud-host`, which includes the minimal set plus `jq`
and `htop` for application-host operations:

```bash
sudo ./jlx-cloud --provider ubuntu
sudo ./jlx-cloud --provider ubuntu --host
sudo ./jlx-cloud --provider oci --host --swap-gib 2
```

Preview profile selection without changing the current machine:

```bash
./jlx-cloud --dry-run
./jlx-cloud --provider oci --host --dry-run
```

## Cloud-init

Ready-to-paste user-data lives under `cloud-init/`:

- `ubuntu-26.04.yaml` enables UFW with SSH allowed.
- `oci-ubuntu-26.04.yaml` leaves the guest firewall unchanged to preserve
  Oracle's provider-managed iSCSI rules and applies conservative A1 tuning.

Both templates default to the minimal profile. To provision an application host,
add `--host` to the second `runcmd` list in the selected YAML file:

```yaml
- [/opt/jlx-cloud/jlx-cloud, --provider, oci, --user, ubuntu, --host, --swap-gib, '2']
```

The templates clone the immutable `v0.1.0` jlx-cloud release. jlx-cloud then
checks out the full dot-jay commit pinned in `config/defaults.env`; it does not
follow dot-jay's moving default branch.

## OCI launch

1. Create a Canonical Ubuntu 26.04 LTS `VM.Standard.A1.Flex` instance with 2
   OCPUs, 12 GB RAM, and an administrator SSH public key.
2. Restrict TCP port 22 to the administrator's source CIDR with an OCI network
   security group or security list.
3. Paste `cloud-init/oci-ubuntu-26.04.yaml` into the initialization-script field,
   adding `--host` when the VM will host applications.
4. Wait for cloud-init and inspect its status before starting another package
   operation.

```bash
cloud-init status --wait --long
sudo less /var/log/cloud-init-output.log
less /opt/dot-jay/log.txt
test ! -f /var/run/reboot-required || echo "Reboot required"
```

Do not use `cloud-init clean` merely to rerun jlx-cloud; provider initialization
modules may run again on the next boot. For a deliberate rerun, update this
root-owned checkout to a reviewed release and invoke `sudo ./jlx-cloud` with the
same provider and mode flags.

## Updating dot-jay

Update `DEFAULT_DOT_JAY_REF` in `config/defaults.env` to a reviewed full commit
ID, run the tests, and release a new jlx-cloud tag. This makes the machine-level
release and its user-environment dependency auditable together.

## Development

```bash
./tests/test.sh
git diff --check
```

CI installs ShellCheck and cloud-init and treats either validator as required.
