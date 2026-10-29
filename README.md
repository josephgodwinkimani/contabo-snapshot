# Contabo VPS Snapshot

Simple bash script that keeps a rolling snapshot of chosen [Contabo VPS](https://contabo.com/en/vps/) instances using the [Contabo API](https://api.contabo.com/).

## Requirements

`bash`, `curl` and `jq`. `flock` (util-linux) is used when present so that two runs cannot overlap. `logger` is used when present to write errors to syslog.

## Setup

- `git clone` this repository
- copy `config.conf.template` to `config.conf` and run `chmod 600 config.conf`
- put your Contabo credentials in `config.conf` and set `INSTANCE_IDS` to the instances you want to snapshot
- test the login and the access to your instances: `./contabo_snapshot.sh --check`
- see what a run would do without changing anything: `./contabo_snapshot.sh --dry-run`
- take a snapshot: `./contabo_snapshot.sh`

The API user and password are the Contabo API credentials from the Customer Control Panel. The password is the separate API password and not your account password. The script reads `config.conf` as shell code so keep every value in single quotes. It refuses a `config.conf` that other users can write and it warns when other users can read it.

## Settings

| Setting | Default | Meaning |
|---|---|---|
| `CLIENT_ID` `CLIENT_SECRET` `API_USER` `API_PASSWORD` | required | Contabo API credentials |
| `INSTANCE_IDS` | required | Numeric instance ids separated by spaces. Other instances of the account are never touched. The script stops if this is empty |
| `SNAPSHOT_LIMIT` | `1` | Snapshots your plan allows per instance (1 to 10) |
| `ROTATE_PREFIX` | `auto-` | Only snapshots whose name starts with this are rotated and new snapshots get it |
| `ALLOW_DELETE_UNMANAGED` | `0` | `1` lets the script delete snapshots without the prefix to make room |
| `SNAPSHOT_DESCRIPTION` | `Automatic snapshot by contabo_snapshot.sh` | Description of new snapshots |
| `LOCK_FILE` | `/var/lock/contabo_snapshot.lock` | Lock file that stops parallel runs |

The instance id is the `instanceId` shown in the Contabo Customer Control Panel and returned by `GET https://api.contabo.com/v1/compute/instances`.

## Options

- `--check` tests the login and that each instance and its snapshots can be read
- `--list` prints the snapshots of each instance
- `--dry-run` does every read and prints what would be deleted and created
- `-h` or `--help` prints the usage

None of these options changes anything at Contabo.

## What a run does

For each instance in `INSTANCE_IDS` the script reads the snapshots and counts the ones named with `ROTATE_PREFIX`. If the number of snapshots is below `SNAPSHOT_LIMIT` it creates a new snapshot named `auto-YYYYmmdd-HHMMSS` and deletes nothing. If the limit is reached it deletes the oldest managed snapshots needed to make room and then creates the new one. Afterwards it reads the list again and checks that the new snapshot is there.

Snapshots without the prefix, for example one you made by hand before a risky change, are never deleted. They still count towards the limit. If the limit is reached and only such snapshots are in the way the script changes nothing and exits with status 3. Delete one by hand or set `ALLOW_DELETE_UNMANAGED=1`.

With a limit of 1 the old snapshot has to be deleted before the new one can be created so there is a short moment without a snapshot. If creating the new snapshot fails after a delete the script prints a `CRITICAL` line and exits with status 1. The script never restores a snapshot.

The script checks the login and the shape of every answer before it acts and it never deletes a snapshot whose id it cannot read. Reads are retried and a refused token causes one new login. The credentials and the token are passed to curl on standard input and are never printed or visible in the process list.

## Exit status

| Status | Meaning |
|---|---|
| 0 | Done |
| 1 | An error occurred or another run is in progress |
| 2 | Configuration or login problem. Nothing was changed |
| 3 | An instance was skipped because only unmanaged snapshots are in the way. Nothing was deleted |

## Cron

The script writes to standard output. Redirect it to a log file:

```
0 0 * * * /home/contabo-snapshot/contabo_snapshot.sh >> /var/log/contabo-snapshot.log 2>&1
```

Check the first runs with `--dry-run` and read the log after the first night.

## Upgrading from the earlier version

The earlier version snapshotted every instance of the account and deleted the oldest snapshot on every run. Add `INSTANCE_IDS` to your `config.conf` before the next run because the new version stops without it. Snapshots made by the earlier version are named by their timestamp only and do not start with `auto-`. They are treated as hand made and are not deleted so remove them yourself or set `ALLOW_DELETE_UNMANAGED=1` once. The credentials keep the same names.
