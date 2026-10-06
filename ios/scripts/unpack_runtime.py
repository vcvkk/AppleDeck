#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Unpack DroidDeck's runtime tarball, wherever it is running.

The archive is a rootfs that DroidDeck unpacks over its own files directory on
Android, where the tar implementation creates directories the archive does not
mention. GNU tar does the same; macOS's bsdtar does not, and stops with

    ./usr/share/terminfo/P/P8-W: Can't create ...: No such file or directory

for a file whose parent the archive never declared. That is not a broken archive:
it is an implementation difference between the two tars, and it is the whole
reason this script exists.

Parents are created here, explicitly, for every member. Everything else is a
straightforward streaming extract: regular files, directories, symlinks, hard
links, and the mode bits - the runtime is full of symlinks between /usr/lib and
/lib and of binaries that have to stay executable.
"""

from __future__ import annotations

import os
import subprocess
import sys
import tarfile

# Members that are not worth extracting and that a filesystem may refuse.
SKIP_IF = {"fifo", "chardev", "blockdev"}


def parents(path: str) -> None:
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)


def safe_join(dest: str, name: str) -> str | None:
    """Join, and refuse anything that climbs out of the destination.

    An archive is input like any other. This one is fetched over https from a
    URL in a catalogue and verified against a sha256 in that catalogue, so the
    threat is not theoretical - it is just not the one that should stop us.
    """
    target = os.path.normpath(os.path.join(dest, name.lstrip("./")))
    root = os.path.normpath(dest)
    if target != root and not target.startswith(root + os.sep):
        print(f"skipping {name}: outside the destination", file=sys.stderr)
        return None
    return target


def main() -> int:
    if len(sys.argv) != 3:
        print(f"usage: {sys.argv[0]} <archive.tar.zst> <destination>", file=sys.stderr)
        return 2
    archive, dest = sys.argv[1], sys.argv[2]
    os.makedirs(dest, exist_ok=True)

    # Streamed through zstd rather than read whole: the archive is 754 MB and the
    # runner's disk is not something to spend twice.
    decompressor = subprocess.Popen(["zstd", "-dc", archive], stdout=subprocess.PIPE)
    count = {"file": 0, "dir": 0, "link": 0}
    try:
        with tarfile.open(fileobj=decompressor.stdout, mode="r|") as tar:
            for member in tar:
                if member.isdev() or member.isfifo():
                    continue
                target = safe_join(dest, member.name)
                if target is None:
                    continue
                if member.isdir():
                    os.makedirs(target, exist_ok=True)
                    os.chmod(target, member.mode & 0o7777)
                    count["dir"] += 1
                    continue
                # Every other kind needs its parent, whether or not the archive
                # declared it. This is the fix.
                parents(target)
                if member.issym():
                    if os.path.islink(target) or os.path.exists(target):
                        os.remove(target)
                    os.symlink(member.linkname, target)
                    count["link"] += 1
                elif member.islnk():
                    source = safe_join(dest, member.linkname)
                    if source and os.path.exists(source):
                        if os.path.exists(target):
                            os.remove(target)
                        os.link(source, target)
                        count["link"] += 1
                elif member.isfile():
                    source = tar.extractfile(member)
                    if source is None:
                        continue
                    with open(target, "wb") as out:
                        while True:
                            chunk = source.read(1 << 20)
                            if not chunk:
                                break
                            out.write(chunk)
                    # The mode has to survive: the runtime's start scripts are
                    # invoked directly, and an unpacked tree without its bits is a
                    # rootfs that boots to nothing.
                    os.chmod(target, member.mode & 0o7777)
                    count["file"] += 1
    finally:
        if decompressor.stdout:
            decompressor.stdout.close()

    # Checked after the block, not inside finally: a return in a finally swallows
    # everything else, which the compiler warns about for a reason.
    status = decompressor.wait()
    if status not in (0, None):
        print(f"zstd exited {status}", file=sys.stderr)
        return 1

    print(f"unpacked {count['file']} files, {count['dir']} directories, "
          f"{count['link']} links into {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())