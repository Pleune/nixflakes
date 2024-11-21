#!/usr/bin/env python3

from subprocess import run, PIPE, DEVNULL
import json
import os
from datetime import datetime, timezone
from dateutil.parser import parse as parsedate
import shutil
from argparse import ArgumentParser


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
    "--rustic",
    type=str,
    default=str(shutil.which("rustic")),
    help="absolute path to restic",
)
parser.add_argument(
    "--default-days", type=int, default=7, help="days between backups if not specified"
)
parser.add_argument("--profile", type=str, default=None, help="passed to rustic -P")
parser.add_argument("--dry-run", action="store_true", help="run restic with --dry-run")
parser.add_argument("--live", action="store_true", help="don't stop instances")
args = parser.parse_args()

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


def backup(name, wait_days):
    tar = f"{name}.tar"
    label = f"incus-export-{name}"

    print(f"backup {name}, wait_days={wait_days}")

    # ?? I don't really understand this format...
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
    for table in json.loads(snapshot_tables.stdout):
        for snapshot in table:
            if isinstance(snapshot, list):
                for s in snapshot:  # I don't know what this is supposed to be?
                    time = parsedate(s["time"])
                    days = (script_start - time).days
                    print(f"{days} since backup, wait_days={wait_days}")
                    if days < wait_days - 0.5:
                        print(f"Skipping {name} because it has only been {days} days")
                        return


    was_running = False
    if not args.live:
        print(f"stopping {name}")
        was_running = run([args.incus, "stop", name], stderr=DEVNULL).returncode == 0

    print(f"exporting {name}")
    run(
        [
            args.incus,
            "export",
            name,
            tar,
            "-v",
            "--compression",
            "none",
            "--instance-only",
        ],
        check=True,
    )

    try:
        if not args.live and was_running:
            print(f"restarting {name}")
            run([args.incus, "start", name], check=True)

        run(
            [
                args.rustic,
                "backup",
                tar,
                "--tag",
                "incus-export",
                "--label",
                label,
            ]
            + (["--dry-run"] if args.dry_run else [])
            + (["-P", args.profile] if args.profile is not None else []),
            check=True,
        )
    finally:
        os.remove(f"{name}.tar")


tmpdir = f"/tmp/incus-backup-{datestr}"

try:
    os.mkdir(tmpdir)
except FileExistsError as _:
    pass

os.chdir(tmpdir)
print(f"using tmpdir '{tmpdir}'")

incus_list = run([args.incus, "list", "-f", "json"], stdout=PIPE, check=True)
for instance in json.loads(incus_list.stdout):
    try:
        name = instance["name"]
        print(f"running {name}...")
        if "user.backup" in instance["config"]:
            b = instance["config"]["user.backup"]
            days = args.default_days
            if "user.backup_every_days" in instance["config"]:
                days = int(instance["config"]["user.backup_every_days"])
                if days == 0:
                    days = args.default_days

            if isinstance(b, str) and b == "true":
                backup(name, days)
            elif isinstance(b, bool) and b:
                backup(name, days)
    except Exception as e:
        print("Failed to process instance")
        print(e)

print(f"cleaning up {tmpdir}")
os.chdir("/tmp")
shutil.rmtree(tmpdir)
