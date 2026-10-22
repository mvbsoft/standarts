"""The sample migration of tests/project. It sets the schema of the data to this version and logs
the run with the answer of the application that serves at that moment ("none" when none does), so
the test sees that the migration of the new image ran while the old version still served."""
import os
import sys
import urllib.request

import app

FAIL = False


def serving():
    try:
        with urllib.request.urlopen("http://app:8000/", timeout=2) as answer:
            return answer.read().decode()
    except OSError:
        return "none"


if __name__ == "__main__":
    if FAIL:
        sys.exit("migrate: this migration fails on purpose")
    with open(os.path.join(app.DATA_DIR, "migrations.log"), "a", encoding="utf-8") as log:
        log.write(f"{app.VERSION} {serving()}\n")
    with open(app.SCHEMA, "w", encoding="utf-8") as schema:
        schema.write(str(app.VERSION))
    print(f"migrate: schema {app.VERSION}")
