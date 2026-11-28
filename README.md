# kitchen-parallels

Run Test Kitchen against disposable Linux and Windows VMs on Parallels Desktop.
The driver uses `prlctl` on the Mac and Kitchen's SSH or WinRM transport.

## Requirements

- Ruby 3.1 or newer and Test Kitchen 4.2 or newer.
- Parallels Desktop with full CLI access in the current macOS user session.
- A prepared guest for the Mac's CPU architecture, with Parallels Tools and
  an account suitable for your provisioner. Linux uses shared networking and
  SSH. See the Windows guest and tunnel requirements below.
- Enough local disk space for a full copy per instance.

Run one instance at a time from a base image that shares its DHCP client ID
across copies. For concurrent instances, prepare the guest to obtain an address
using the NIC's MAC address or another unique DHCP client ID.

## Install from this checkout

Run `bundle install` in this checkout to install Test Kitchen and the
provisioners for the Apache smoke tests. Set `TEST_KITCHEN_PATH` to use a
compatible local Test Kitchen checkout.

To use this driver from another project, add `kitchen-parallels` to its
Gemfile. Bundler installs a compatible Test Kitchen version.

## Use a box from disk or a mounted NAS

```yaml
driver:
  name: parallels

provisioner:
  name: shell
  command: uname -m

platforms:
  - name: ubuntu-24.04
    driver:
      box: /Volumes/nfs/bentox_boxes/ubuntu-24.04-202510.26.0-parallels-arm64.box
  - name: debian-12
    driver:
      box: /Volumes/nfs/bentox_boxes/debian-12-202510.26.0-parallels-arm64.box

suites:
  - name: default
```

Kitchen uses its SSH transport by default on Linux. For a Bento `.box`, the
driver installs a fresh SSH key for the `vagrant` user through Parallels Tools,
removes the known Vagrant bootstrap keys from that guest and keeps the private
key with the instance until destroy. Set `transport.ssh_key` or
`transport.password` to use explicit credentials, or set `insert_key: false`
to use the transport configuration as written. Standalone `.pvm` bundles and
registered VMs use your configured credentials by default.

Use only trusted, self-contained images. A `.box`
must contain one top-level `.pvm` bundle and a `metadata.json` declaring
`"provider": "parallels"`. A standalone `.pvm` directory also works as the
`box` value. To use a new image, put it on disk or mount its share, point
`box` at it, then run `kitchen create`. Kitchen extracts or copies the image
into its local `.kitchen` directory and registers that copy in Parallels.

To use an already registered VM, set `source_vm` to its name or UUID in place
of `box`. Shut down the registered source first. Parallels creates a full
clone and Kitchen boots the clone.

```sh
bundle exec kitchen create
bundle exec kitchen converge
bundle exec kitchen destroy
```

The optional `driver.ip_timeout` sets how long the driver waits for a guest
IPv4 address, in seconds. It defaults to 180. The transport readiness timeout is
configured separately with `transport.max_wait_until_ready`.
The driver checks the address reported by Parallels Tools first and uses
active Parallels DHCP leases for the VM's MAC address as a fallback.

Set `driver.cpus` for the number of virtual processors and `driver.memory`
for the memory in megabytes. Both accept positive integers. You can set them
independently, and the VM keeps the source image's setting for each option
you omit. If an imported image has a saved session and you specify either
option, Kitchen discards the imported copy’s saved session and boots it
with the requested hardware.

```yaml
driver:
  name: parallels
  cpus: 3
  memory: 2048
```

## Windows over WinRM

WinRM uses the loopback SSH tunnel described below. Leave `network_mode` unset
to inherit the source adapter, or set it to `shared` or `host-only`.
Use the Linux/SSH workflow for bridged mode, `static_ip` and `port_forward`.

On Apple silicon, install Windows 11 Pro from the
[Microsoft Arm64 ISO](https://www.microsoft.com/en-us/software-download/windows11arm64)
using the Windows 11 VM profile and shared networking. Disable host folder
sharing for the source, install Parallels Tools, and use dedicated local test
credentials. Detach the ISO and shut Windows down before using the VM as a
clone source. Keep the source and all private keys local.

Use a stopped Windows 11 source VM supported by your Parallels Desktop version
and Mac architecture, with Parallels Tools, working guest IPv4 networking and
a dedicated account authorised for WinRM. Prepare the source with a WinRM
listener reachable on the guest's loopback interface. Block inbound WinRM on
the guest's network interfaces. For the smoke example, use HTTPS on guest port
5986, with a certificate trusted by the macOS Ruby installation and a subject
alternative name matching `127.0.0.1`. Enable WinRM certificate authentication
and map a dedicated client certificate to the guest account.

Kitchen connects to `127.0.0.1` on the Mac by default when you select
`transport.name: winrm`. The driver prints the clone's IPv4 address while
waiting for WinRM. It skips Linux SSH key insertion and rejects enabled
`driver.synced_folders` entries with WinRM. Use a separate local tunnel port
for each running clone. During create the driver writes a temporary marker
through Parallels Tools in the selected clone and checks for it over WinRM.
The WinRM account needs read access to the marker in ProgramData. If your shell configures HTTP proxies, include
`127.0.0.1` in its proxy bypass list.

1. From `examples/windows`, supply `KITCHEN_PARALLELS_WINDOWS_VM`,
   `KITCHEN_WINRM_CLIENT_CERT` and `KITCHEN_WINRM_CLIENT_KEY` in the environment.
   Use absolute paths to the PEM certificate and its private key. Keep
   `transport.no_ssl_peer_verification: false` explicit in your Kitchen
   configuration to verify the server certificate.
   Run `BUNDLE_GEMFILE=../../Gemfile bundle exec kitchen create`.

2. Open an SSH tunnel in a second terminal using the clone IP printed by Kitchen.
   The guest needs Windows OpenSSH Server, a trusted host key and a tunnel account
   permitted to forward to guest loopback. For example:

   ```sh
   ssh -N -o ExitOnForwardFailure=yes -L 127.0.0.1:15986:127.0.0.1:5986 tunnel-user@CLONE_IP
   ```

   If SSH reports that the port is occupied, use a free port and update
   `transport.port` before retrying `kitchen create`.

3. Keep the tunnel open and run the following from `examples/windows`.

   ```sh
   BUNDLE_GEMFILE=../../Gemfile bundle exec kitchen converge
   BUNDLE_GEMFILE=../../Gemfile bundle exec kitchen verify
   BUNDLE_GEMFILE=../../Gemfile bundle exec kitchen destroy
   ```

If creation times out before the tunnel is ready, retry `kitchen create` after
the tunnel is up. The driver reuses the same clone. If converge or verify loses
the connection, re-establish the tunnel to that clone and rerun the failed
command. `kitchen destroy` also works after a failed WinRM connection. Close
the tunnel once the clone is destroyed.

## VM networking

With no networking options, the VM keeps the image's adapter settings. Set
`driver.network_mode` to `shared`, `host-only` (private to the host and its
VMs), or `bridged` (the default host bridge). Explicit settings apply to the
image's first network adapter, `net0`. Use an image with one network adapter.
Bridged mode exposes the guest to the LAN as soon as it boots. Use an image
with secure SSH credentials already installed and set `insert_key: false`.

For a static address, set `driver.static_ip` to an unused IPv4 address with a
CIDR prefix on the selected network. Start with a DHCP-configured image.
Static addressing requires Parallels Tools and guest support for applying its
IPv4 settings. On guests using Netplan with systemd-networkd, Kitchen writes
a Netplan override for the adapter to disable IPv4 DHCP and set the address.
Kitchen checks the address and prefix in the guest before connecting. For
example, on a host-only subnet with an address
reserved outside DHCP allocation:

```yaml
driver:
  name: parallels
  network_mode: host-only
  static_ip: 10.37.129.10/24
```

For a TCP port forward, set `driver.port_forward` to
`{ host_port: 22080, guest_port: 8080 }`. This selects shared networking when
no mode is supplied. The rule can expose the guest service to systems that
can reach the host port. Kitchen continues to use the guest IP for SSH.
Kitchen removes its rule during destroy. UDP, multiple forwards, IPv6 static
addresses, and bridge interface selection are outside these options. Destroy
and recreate an instance when changing its network configuration.

## Package a stopped instance

Shut down the guest without destroying the Kitchen instance, then run
`kitchen package INSTANCE`. Kitchen writes `INSTANCE.box` in the project root
and leaves the source VM registered and stopped. Use the resulting file as
`driver.box` in another instance. An existing output file is preserved.

Create a fresh instance from a reviewed `.box` archive that contains no
Kitchen-injected SSH keys. Set `driver.package_source_sha256` to the SHA-256
digest of that specific archive before creating the instance, set
`driver.insert_key: false`, and supply your own transport credentials.
Kitchen checks the archive against the digest during import. Inspect the
base guest for inherited credentials before approving it. Existing instances,
registered `source_vm` clones, and direct `.pvm` imports lack this import record.

The package retains guest files and credentials you add. Eject optical
images completely and keep virtual hard disks inside the VM bundle.
Kitchen removes custom host shares and disables host sharing on the export clone.

## Shared folders and disks

Add the options under the global driver to share them across platforms, or
under a platform's driver to configure that guest.

```yaml
driver:
  name: parallels
  synced_folders:
    - ["data/%{instance_name}", "/mnt/fixtures", {create: true, readonly: true}]
  additional_disks:
    - name: scratch
      size_gb: 4
```

The driver mounts native Parallels shared folders at the requested guest paths.
The optional YAML map supports `type: parallels`, `create`, `disabled`,
`readonly` and `mount_options`. The extra disks are blank and are deleted with
the VM. Format and mount them in the provisioner if your tests need a filesystem.
Destroy and recreate the instance to apply volume changes.

## Restore a snapshot

Use the exact instance name from `kitchen list`. Find its Parallels VM UUID in
`.kitchen/INSTANCE.yml` under `parallels_uuid`. Run
`prlctl list VM_UUID --info --json` and verify its registered name matches both
`parallels_name` and `kitchen-INSTANCE-TOKEN`, where `TOKEN` is the saved
`parallels_token`. Shut down the disposable guest before taking or restoring a
snapshot. Run these commands one at a time for the instance.

```sh
prlctl stop VM_UUID
prlctl snapshot VM_UUID --name baseline
prlctl snapshot-list VM_UUID --json
bundle exec kitchen-parallels restore INSTANCE SNAPSHOT_UUID
bundle exec kitchen create INSTANCE
```

Restore uses the saved VM UUID and checks the registered VM name against
Kitchen's ownership token. This works for Kitchen imports and full clones
whose registered names still match the state file. The source VM and source
box are untouched. Pass a snapshot UUID from that VM's inventory, with or
without braces. Running, paused and suspended VMs and snapshots taken while
the guest was running are outside this workflow.

Restoring rolls the guest disks and VM settings back to the selected snapshot.
Host files in shared folders retain their current contents. Kitchen checks the
snapshot inventory and rechecks VM ownership and power state before switching.
It clears the recorded lifecycle stage and address before attempting the switch,
so a failed or interrupted attempt may also leave those values cleared. A
successful restore confirms that the selected snapshot is current and the VM
is stopped. If the result is uncertain, check the snapshot inventory and VM
status before continuing. Once the restore is confirmed, `kitchen create`
starts the same VM and refreshes access before you use `kitchen exec` or
converge again. Keep the Kitchen state and any generated SSH key until you
destroy the instance.

## Rsync uploads

With `kitchen-sync` installed, set `transport.name: rsync`. It still uses
SSH and the key configured by the driver. The tested `kitchen-sync` 2.2.2.pre
requires `rsync` on both machines, an RSA identity in the host SSH agent and a
provisioner that opens SSH before uploading. With the shell provisioner, use
`script:` to run a script and `data_path:` to supply a directory to transfer.
Use the default SSH transport if you use the shell provisioner's single-command
mode. That mode can reach the upload step before opening a session.

## Using a shared box catalog

To select a named box, set `driver.box_manifest` or `KITCHEN_BOX_MANIFEST`,
then set each platform's `driver.box` to a map with `name` and an exact
`version`. The driver selects the provider and host architecture. Kitchen
copies the archive into its shared local cache and verifies it before import.
Subsequent imports reuse that copy. Set `KITCHEN_BOX_CACHE` or `driver.box_cache`
to choose a cache location. The driver keeps a lease until `kitchen destroy`
succeeds, so the prune preview protects archives used by active instances.

```sh
kitchen box list --manifest /Volumes/nfs/bentox_boxes/manifest.json --architecture arm64
kitchen box doctor --manifest /Volumes/nfs/bentox_boxes/manifest.json --name bento/ubuntu-24.04 --provider parallels --architecture arm64 --checksum
kitchen box prune --dry-run --provider parallels
```

Both commands accept `--json`. Doctor checks paths and sizes by default.
`--checksum` reads the contents of each selected archive. The commands work
outside a Kitchen project.

## Vagrant compatibility

The driver covers local boxes, Linux SSH bootstrap, native shared folders and
blank extra disks. These Vagrant features still need a separate implementation
or a different driver:

- Remote box lookup, downloads, automatic version checks and updates.
- Other hypervisors.
- Linked clones, Vagrantfile hooks, arbitrary
  provider customisation, Vagrant provisioning and guest environment settings.
- NFS, SMB and Vagrant rsync shared folders, host or guest tool management, and
  the Vagrant Chef cache options.

Kitchen tracks each disposable VM in its instance state. If `create` fails
after registration, retry it after fixing the cause or run `kitchen destroy`
to remove the failed instance and its local copy. Destroy the instance before
switching its source image or removing its `.kitchen` state.

## Status and diagnostics

Run `kitchen list --live` to see the state reported by Parallels for each
managed VM. Add `--probe` to check transport connectivity as well.
Run `kitchen doctor` to check host access and the configured VM source before
creating an instance. These checks read the provider and local configuration
without starting or modifying VMs.

## Apache smoke tests

Mount the NAS or set `KITCHEN_BOX_MANIFEST` to a manifest containing the
pinned Bento Ubuntu 24.04 box for your platform. Alternatively, set
`KITCHEN_PARALLELS_UBUNTU_BOX` to a local box archive. Install Cinc Workstation
with `cinc-cli` on `PATH` for the Cinc suite.

Run these commands from the driver checkout:

```sh
bundle install
bundle exec ruby examples/apache2/run.rb test cinc --destroy always
bundle exec ruby examples/apache2/run.rb test puppet --destroy always
bundle exec ruby examples/apache2/run.rb test ansible --destroy always
```

Each suite creates its own VM, provisions Apache, verifies the service is
enabled and returns HTTP 200, and destroys the VM. Cinc and Ansible also
check that a second apply makes no changes. Puppet and Ansible install their
runtimes from the Ubuntu package repositories before applying the examples.
