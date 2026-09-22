# jlx-cloud

jlx-cloud prepares Ubuntu cloud machines and then delegates user-level package
and shell configuration to a pinned [dot-jay](https://github.com/annaduraij/dot-jay)
revision.

The boundary is intentional:

- jlx-cloud owns OS updates, SSH hardening, firewall policy, unattended upgrades,
  provider checks, swap, sysctl settings, and the provisioning lifecycle.
- dot-jay owns Linux package selection, shell configuration, Git preferences, and
  SSH client configuration for the login user.

The end-to-end bootstrap is automatic. Cloud-init installs and runs jlx-cloud;
jlx-cloud downloads a checksum-pinned, sanitized dot-jay runtime bundle and runs
the selected dot-jay profile for the Ubuntu login user. No GitHub token is placed
in OCI user data.

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

Generate the exact cloud-init YAML to paste into a provider console:

```bash
# Minimal OCI server; print the YAML in the terminal.
./jlx-cloud render --provider oci

# Application host; copy the YAML directly on macOS.
./jlx-cloud render --provider oci --host | pbcopy

# Or save an auditable artifact before launching the instance.
./jlx-cloud render --provider oci --host > /tmp/jlx-cloud-oci.yaml
```

The renderer is deterministic and does not change the local machine. It selects
the released template and safely applies `--host`, `--user`, and `--swap-gib`.
There is no compile step: its output is the final cloud-init document.

The source templates live under `cloud-init/`:

- `ubuntu-26.04.yaml` enables UFW with SSH allowed.
- `oci-ubuntu-26.04.yaml` leaves the guest firewall unchanged to preserve
  Oracle's provider-managed iSCSI rules and applies conservative A1 tuning.

The templates clone the immutable `v0.2.0` jlx-cloud release. jlx-cloud then
downloads the runtime bundle for the full dot-jay commit pinned in
`config/defaults.env`; it does not follow dot-jay's moving default branch.
The bundle checksum is pinned alongside its URL.

The public bundle contains only the cloud profiles and their runtime dependencies:
the seven cloud packages, base/CLI shell modules, runtime Python, generic SSH
config, and a Git config with personal identity fields removed. It excludes the
dot-jay README, `.env`, docs, application configs, unrelated profiles, SSH
identity catalogs, public/private keys, tests, and development files.

## OCI launch

1. Create a Canonical Ubuntu 26.04 LTS `VM.Standard.A1.Flex` instance with 2
   OCPUs, 12 GB RAM, and an administrator SSH public key.
2. Restrict TCP port 22 to the administrator's source CIDR with an OCI network
   security group or security list.
3. Under **Advanced options → Management → Initialization script**, paste the
   output of `./jlx-cloud render --provider oci --host`. OCI Console performs
   the required base64 encoding.
4. Wait for cloud-init and inspect its status before starting another package
   operation.

```bash
cloud-init status --wait --long
sudo less /var/log/cloud-init-output.log
less /opt/dot-jay/log.txt
test ! -f /var/run/reboot-required || echo "Reboot required"
```

To launch with OCI CLI instead, save the rendered YAML and pass it directly to
Oracle's `--user-data-file` option; do not base64-encode it yourself:

```bash
./jlx-cloud render --provider oci --host > /tmp/jlx-cloud-oci.yaml

oci compute instance launch \
  --availability-domain "$availability_domain" \
  --compartment-id "$compartment_id" \
  --image-id "$image_id" \
  --subnet-id "$subnet_id" \
  --shape VM.Standard.A1.Flex \
  --user-data-file /tmp/jlx-cloud-oci.yaml
```

Add the normal shape configuration, SSH key, and networking flags required by
your tenancy. `--user-data-file` is a convenience wrapper around OCI metadata's
base64-encoded `user_data` field.

Do not use `cloud-init clean` merely to rerun jlx-cloud; provider initialization
modules may run again on the next boot. For a deliberate rerun, update this
root-owned checkout to a reviewed release and invoke `sudo ./jlx-cloud` with the
same provider and mode flags.

## Updating dot-jay

Build the public runtime strictly from a reviewed, committed dot-jay ref rather
than from its working tree:

```bash
python3 scripts/build-dot-jay-bundle.py \
  --source-repo ../jay-main \
  --ref <full-dot-jay-commit> \
  --output-dir dist
```

Review the archive listing, update `DEFAULT_DOT_JAY_REF`, bundle URL, and SHA-256
in `config/defaults.env`, run the tests, and attach the archive to the matching
jlx-cloud GitHub release. The builder uses an allowlist, removes Git identity
defaults, scans secret signatures, and emits deterministic archive metadata.

## Development

```bash
./tests/test.sh
git diff --check
```

CI installs ShellCheck and cloud-init and treats either validator as required.
