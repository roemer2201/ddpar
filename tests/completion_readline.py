#!/usr/bin/env python3
"""Exercise real Tab expansion in Bash/Readline using only the standard library."""

import os
from pathlib import Path
import pty
import re
import select
import shlex
import signal
import tempfile
import time
import unittest


class ReadlineCompletion(unittest.TestCase):
    """Catch quoting regressions that a noninteractive compgen call cannot see."""

    def read_until(self, pattern):
        data = b""
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            if select.select([self.fd], [], [], 0.1)[0]:
                data += os.read(self.fd, 65536)
                match = re.search(pattern, data)
                if match:
                    return match
        self.fail(f"Readline timed out waiting for {pattern!r}: {data!r}")

    def test_tab_expansion(self):
        completion = Path(__file__).resolve().parents[1] / "completions/ddpar"
        with tempfile.TemporaryDirectory(prefix="ddpar-completion-") as directory:
            root = Path(directory)
            (root / "input image").touch()
            (root / "backup dir").mkdir()
            (root / "backup dir/disk image-metadata.txt").touch()
            (root / "$(touch INJECTED)-metadata.txt").touch()
            (root / "quote' image-metadata.txt").touch()
            self.pid, self.fd = pty.fork()
            if self.pid == 0:
                env = dict(os.environ, INPUTRC="/dev/null", TERM="dumb")
                os.execvpe("bash", ["bash", "--noprofile", "--norc", "-i"], env)
            try:
                self.read_until(rb"[#\$] ")
                command = (
                    "PS1='DDPAR-READY> '; set -o emacs; "
                    "source /usr/share/bash-completion/bash_completion; "
                    f"source {shlex.quote(str(completion))}; "
                    f"cd {shlex.quote(directory)}; "
                    "bind -x '\"\\C-x\\C-r\":printf \"LINE[%s]\\n\" \"${READLINE_LINE}\"'"
                )
                os.write(self.fd, (command + "\n").encode())
                self.read_until(rb"DDPAR-READY> $")
                cases = [
                    ("ddpar -m ba", "ddpar -m backup "),
                    ("ddpar -csmba", "ddpar -csmbackup "),
                    ("ddpar -o input\\ im", "ddpar -o input\\ image "),
                    ("ddpar -o 'input im", "ddpar -o 'input image' "),
                    ("ddpar-restore -yPoinput\\ im", "ddpar-restore -yPoinput\\ image "),
                    ("ddpar-restore -i backup\\ dir/disk", "ddpar-restore -i backup\\ dir/disk\\ image "),
                    ("ddpar-restore -i 'backup dir/disk", "ddpar-restore -i 'backup dir/disk image' "),
                    ('ddpar-check -b "backup dir/disk', 'ddpar-check -b "backup dir/disk image" '),
                    ("ddpar-check -bbackup\\ dir/disk", "ddpar-check -bbackup\\ dir/disk\\ image "),
                    ("ddpar -m backup -o input", "ddpar -m backup -o input"),
                    ("ddpar -r -o input", "ddpar -r -o input"),
                    ("ddpar -- input", "ddpar -- input"),
                    ("ddpar-restore -i quote", "ddpar-restore -i quote\\'\\ image "),
                ]
                for typed, expected in cases:
                    with self.subTest(typed=typed):
                        os.write(self.fd, typed.encode() + b"\t\x18\x12")
                        result = self.read_until(rb"LINE\[([^\r\n]*)\]\r\n").group(1).decode()
                        self.assertEqual(result, expected)
                        os.write(self.fd, b"\x15")
                self.assertFalse((root / "INJECTED").exists())
            finally:
                os.kill(self.pid, signal.SIGKILL)
                os.close(self.fd)
                os.waitpid(self.pid, 0)


if __name__ == "__main__":
    unittest.main()
