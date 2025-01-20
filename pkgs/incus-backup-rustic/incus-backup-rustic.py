#!/usr/bin/env python3

from argparse import ArgumentParser
from datetime import datetime, timezone, timedelta
from dateutil.parser import parse as parsedate
from subprocess import run, PIPE, DEVNULL
from textwrap import indent
import json
import os
import requests_unixsocket
import shutil
import time
import traceback

parser = ArgumentParser(
    prog="incus-backup-rustic",
    description="backup incus instances using rustic every n days, based on their yaml configs.",
)
parser.add_argument(
    "--incus",
    type=str,
    default=str(shutil.which("incus")),
    help="absolute path to incus",
)
parser.add_argument(
    "--mount",
    type=str,
    default=str(shutil.which("mount")),
    help="absolute path to mount",
)
parser.add_argument(
    "--umount",
    type=str,
    default=str(shutil.which("umount")),
    help="absolute path to umount",
)
parser.add_argument(
    "--sudo",
    type=str,
    default=str(shutil.which("sudo")),
    help="absolute path to sudo",
)
parser.add_argument(
    "--rustic",
    type=str,
    default=str(shutil.which("rustic")),
    help="absolute path to rustic",
)
parser.add_argument(
    "--default-days", type=int, default=7, help="days between backups if not specified"
)
parser.add_argument("--incus-socket", type=str, default="/var/lib/incus/unix.socket")
parser.add_argument("--profile", type=str, default=None, help="passed to rustic -P")
parser.add_argument("--dry-run", action="store_true", help="run rustic with --dry-run")
parser.add_argument("--live", action="store_true", help="don't stop instances")
parser.add_argument(
    "--shutdown-wait",
    type=int,
    default=10800,
    help="How many seconds to wait for an instance to shutdown",
)
args = parser.parse_args()

incus_socket = f"http+unix://{args.incus_socket.replace("/", "%2F")}"
session = requests_unixsocket.Session()

if args.profile == "":
    args.profile = None

script_start = datetime.now(timezone.utc)
datestr = datetime.today().strftime("%Y-%m-%d")

if not os.path.isfile(args.incus):
    print("could not find incus")
    exit(-1)
if not os.path.isfile(args.rustic):
    print("could not find rustic")
    exit(-1)


def check_wait_days(label, wait_days):
    snapshot_tables = run(
        [
            args.rustic,
            "snapshots",
            "--filter-label",
            label,
            "--json",
            "--no-progress",
            "--log-level",
            "ERROR",
        ]
        + (["-P", args.profile] if args.profile is not None else []),
        stdout=PIPE,
        check=True,
    )

    days = "n/a"
    for table in json.loads(snapshot_tables.stdout):
        for snapshot in table:
            if isinstance(snapshot, list):
                for s in snapshot:  # I don't know what this is supposed to be?
                    time = parsedate(s["time"])
                    days = (script_start - time).days
                    if days < wait_days - 0.5:
                        print(f"  {days} since backup (skipped)")
                        return False

    print(f"  {days} since backup")
    return True


def incus_wait(id, timeout=30, check=True):
    print(f"  waiting on {id}...")
    start = time.time()
    resp_wait = session.get(
        f"{incus_socket}/1.0/operations/{id}/wait",
        timeout=timeout,
    )
    end = time.time()

    if not resp_wait.status_code == 200:
        raise RuntimeError(f"failed to wait on {id}")

    print(f"  done ({end-start}s)")

    if check:
        if resp_wait.json()["type"] == "error":
            raise RuntimeError(f"wait on {id} error: {resp_wait.content}")

    return resp_wait.json()


def backup_instance(name, wait_days, shutdown_wait):
    print(f"Checking {name}, wait_days={wait_days}")
    tar = f"{name}.tar"
    label = f"incus-export-{name}"

    if not check_wait_days(label, wait_days):
        return

    was_running = False
    if not args.live:
        was_running = True
        print("  stopping")
        resp_stop = session.put(
            f"{incus_socket}/1.0/instances/{name}/state",
            data=json.dumps(
                {
                    "action": "stop",
                    "timeout": 1200,
                }
            ),
        )
        if resp_stop.status_code == 202:
            result_wait = incus_wait(
                resp_stop.json()["metadata"]["id"], timeout=1200, check=False
            )
            if result_wait["type"] == "error" and ("already" in result_wait["error"]):
                was_running = False
            print(f"  was_running={was_running}")
        else:
            raise RuntimeError(f"Failed to stop {name}")

    print("  creating backup")
    resp_backup = session.post(
        f"{incus_socket}/1.0/instances/{name}/backups",
        data=json.dumps(
            {
                "compression_algorithm": "none",
                "expires_at": (
                    datetime.now(tz=timezone.utc) + timedelta(days=1)
                ).isoformat(),
                "instance_only": True,
                "name": "incus-backup-rustic",
                "optimized_storage": False,
            }
        ),
    )

    if resp_backup.status_code == 202:
        incus_wait(resp_backup.json()["metadata"]["id"], timeout=shutdown_wait)
    else:
        raise RuntimeError(f"Failed to create backup on {name}: {resp_backup.content}")

    if not args.live and was_running:
        print("  restarting")
        resp_start = session.put(
            f"{incus_socket}/1.0/instances/{name}/state",
            data=json.dumps(
                {
                    "action": "start",
                    "timeout": 30,
                }
            ),
        )
        if resp_start.status_code == 202:
            was_running = True
            incus_wait(resp_start.json()["metadata"]["id"])
        else:
            print("  Failed to restart!")

    try:
        print("  exporting")
        resp_export = session.get(
            f"{incus_socket}/1.0/instances/{name}/backups/incus-backup-rustic/export",
            stream=True,
        )
        try:
            export_file = None
            if resp_export.status_code == 200:
                export_file = resp_export.raw.fileno()
            else:
                raise RuntimeError("Failed to export backup")

            run(
                [
                    args.rustic,
                    "backup",
                    "--as-path",
                    tar,
                    "--tag",
                    "incus-export",
                    "--label",
                    label,
                    "-",  # stdin
                ]
                + (["--dry-run"] if args.dry_run else [])
                + (["-P", args.profile] if args.profile is not None else []),
                check=True,
                stdin=export_file,
            )
        finally:
            # make sure to close the export connection
            resp_export.close()

    finally:
        # make sure to delete the backup
        print("  deleting backup")
        resp_delete = session.delete(
            f"{incus_socket}/1.0/instances/{name}/backups/incus-backup-rustic"
        )
        if resp_delete.status_code == 202:
            incus_wait(resp_delete.json()["metadata"]["id"])
        else:
            raise RuntimeError("Failed to delete backup")


def backup_storage_zfs(pool, volume, wait_days, zfs_pool):
    label = f"incus-storage-{volume}"

    if not check_wait_days(label, wait_days):
        return

    # only support backing up custom voumes. Backup continer/VM storage with regular instance backup
    pool_path = f"{zfs_pool}/custom/{pool}_{volume}"

    print(f"  mounting {pool_path} to {os.getcwd()}/mnt")
    os.mkdir("mnt")
    run(
        ([] if os.geteuid() == 0 else [args.sudo])
        + [args.mount, "-t", "zfs", pool_path, "./mnt"],
        check=True,
    )

    try:
        # also needs sudo to read all files
        run(
            ([] if os.geteuid() == 0 else [args.sudo])
            + [
                args.rustic,
                "backup",
                "./mnt",
                "--tag",
                "incus-export",
                "--label",
                label,
                "--as-path",
                volume,
            ]
            + (["--dry-run"] if args.dry_run else [])
            + (["-P", args.profile] if args.profile is not None else []),
            check=True,
        )

    finally:
        run(
            ([] if os.geteuid() == 0 else [args.sudo]) + [args.umount, "./mnt"],
            check=True,
        )
        os.rmdir("mnt")


tmpdir = f"/tmp/incus-backup-{datestr}"

try:
    os.mkdir(tmpdir)
except FileExistsError as _:
    pass

os.chdir(tmpdir)
print(f"using tmpdir '{tmpdir}'")


def should_backup(config, backup_key, backup_days_key, default_days):
    if backup_key in config:
        b = config[backup_key]
        days = default_days
        if backup_days_key in config:
            days = int(config[backup_days_key])
            if days == 0:
                days = args.default_days

        if isinstance(b, str) and b == "true":
            return True, days
        elif isinstance(b, bool) and b:
            return True, days
    return False, None


print("Backing up instances")
# incus_list = run([args.incus, "list", "-f", "json"], stdout=PIPE, check=True)
incus_list = session.get(f"{incus_socket}/1.0/instances?filter=&recursion=1")
if incus_list.status_code != 200:
    raise RuntimeError("Failed to get instance list")
for instance in incus_list.json()["metadata"]:
    try:
        name = instance["name"]
        backup, days = should_backup(
            config=instance["config"],
            backup_key="user.backup",
            backup_days_key="user.backup.days",
            default_days=args.default_days,
        )
        if backup:
            backup_instance(name, days, args.shutdown_wait)

    except Exception as _:
        print("!!! Failed to process instance")
        print(indent(traceback.format_exc(), "    "))

print("Backing up storage pools")
# storage_list = run(
#    [args.incus, "storage", "list", "-f", "json"], stdout=PIPE, check=True
# )
storage_list = session.get(f"{incus_socket}/1.0/storage-pools?recursion=1")
if storage_list.status_code != 200:
    raise RuntimeError("Failed to get storage list")
for storage in storage_list.json()["metadata"]:
    storage_name = storage["name"]
    for volume_str in storage["used_by"]:
        try:
            splits = volume_str.split("/")
            if splits[-2] == "custom":
                volume = splits[-1]
                config = storage["config"]
                backup, days = should_backup(
                    config=config,
                    backup_key=f"user.backup.{volume}",
                    backup_days_key=f"user.backup.{volume}.days",
                    default_days=args.default_days,
                )
                if backup:
                    driver = storage["driver"]
                    if driver == "zfs":
                        backup_storage_zfs(
                            storage["name"], volume, days, config["zfs.pool_name"]
                        )
        except Exception as _:
            print("Failed to process storage")
            print(traceback.format_exc())

print(f"cleaning up {tmpdir}")
os.chdir("/tmp")
shutil.rmtree(tmpdir)
