"""Entry point: python3 -I lib/sts_infra/__main__.py <command> ...

Isolated mode keeps the script and working directories off sys.path, so lib/
is added explicitly; nothing else is imported from the environment.
"""
import os
import sys

if sys.version_info < (3, 9):
    sys.stderr.write("ERROR: ./infra needs Python 3.9 or newer\n")
    sys.exit(12)

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from sts_infra.cli import main  # noqa: E402

sys.exit(main())
