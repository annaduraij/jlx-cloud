# Agent Guide for jlx-cloud

jlx-cloud provisions Ubuntu cloud machines and delegates user-level package and
dotfile setup to a pinned dot-jay revision.

## Contract

- `./jlx-cloud` is the public entrypoint.
- The default mode selects the dot-jay `jlx-cloud` profile.
- `./jlx-cloud --host` selects the `jlx-cloud-host` profile.
- `config/defaults.env` is the only default dot-jay repository/ref pin.
- Root-level OS and provider configuration belongs here; user configuration and
  package catalog membership belong in dot-jay.

## Safety

- Never embed tokens, private keys, or other secrets in cloud-init data.
- Keep cloud-init and dot-jay dependencies pinned to immutable releases or full
  commit IDs.
- Do not execute privileged scripts from a checkout writable by the login user.
- OCI provisioning must not enable or reload UFW because Oracle platform images
  contain essential provider-managed iSCSI firewall rules.
- Preserve `--no-sync-private-keys` in every dot-jay invocation.
- Validate effective SSH settings with `sshd -T` before reloading SSH.

## Validation

```bash
./tests/test.sh
./jlx-cloud --dry-run
./jlx-cloud --host --provider oci --dry-run
```

CI additionally requires ShellCheck and `cloud-init schema` validation.
