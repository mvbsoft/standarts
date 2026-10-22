import sys


def read(data, token):
    if len(token) < 16:
        sys.exit("status: STATUS_TOKEN has fewer than 16 characters: "
                 "set a long random one in .env")
    try:
        data["services"] = {}
    except OSError as e:
        data["error"] = f"cannot read the containers: {e}"


def push(data, url, where):
    print(f"status: now {data['status']}: {'pushing to' if url else 'no push, empty'} {where}")
    try:
        data["pushed"] = url
    except OSError as e:
        print(f"status: push failed: {type(e).__name__}: {getattr(e, 'reason', e)}", file=sys.stderr)
