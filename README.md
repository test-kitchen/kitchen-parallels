# kitchen-parallels

Run Test Kitchen against disposable Linux VMs on Parallels Desktop. The driver uses
`prlctl` on the Mac and Kitchen's SSH transport to connect to the guest.

## Requirements

- Ruby 3.1 or newer and Test Kitchen with the shared box cache API.
- Parallels Desktop with full CLI access in the current macOS user session.
- A prepared Linux guest for the Mac's CPU architecture, with Parallels Tools,
  shared networking, SSH and an account suitable for your provisioner.
- Enough local disk space for a full copy per instance.

Run one instance at a time from a base image that shares its DHCP client ID
across copies. For concurrent instances, prepare the guest to obtain an address
using the NIC's MAC address or another unique DHCP client ID.

## Install from this checkout

Run `bundle install` in this checkout. The Gemfile pins a Test Kitchen
revision that includes the shared box cache and installs `kitchen-cinc`
for the Apache example. Set `TEST_KITCHEN_PATH` to use a compatible local
Test Kitchen checkout.

To use this driver from another project, add `kitchen-parallels` and a
compatible Test Kitchen revision to that project's Gemfile.

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
IPv4 address, in seconds. It defaults to 180. The SSH readiness timeout is
configured separately with `transport.max_wait_until_ready`.
The driver checks the address reported by Parallels Tools first and uses
active Parallels DHCP leases for the VM's MAC address as a fallback.

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
- Other hypervisors, Windows and WinRM, port forwarding, bridged and private
  network setup, and static IP configuration.
- Linked clones and snapshots, VM packaging, Vagrantfile hooks, arbitrary
  provider customisation, Vagrant provisioning and guest environment settings.
- NFS, SMB and Vagrant rsync shared folders, host or guest tool management, and
  the Vagrant Chef cache options.

Kitchen tracks each disposable VM in its instance state. If `create` fails
after registration, retry it after fixing the cause or run `kitchen destroy`
to remove the failed instance and its local copy. Destroy the instance before
switching its source image or removing its `.kitchen` state.

## Apache example with Cinc

Install Cinc Workstation so `cinc-cli` is on `PATH`. From this repository,
run:

```sh
bundle install
bundle exec ruby examples/apache2/run.rb test --destroy always
```

The example installs Apache with `cinc_infra`, checks that a second converge
makes no changes, and verifies that Apache is enabled, running and serving
HTTP 200 in the guest. It selects the pinned Ubuntu 24.04 release through the
NAS manifest. Set `KITCHEN_BOX_MANIFEST` to use another manifest, or
`KITCHEN_PARALLELS_UBUNTU_BOX` to override the Parallels archive directly.
