import os
import hmac


def lambda_handler(event, context):
    header = (event.get("headers") or {}).get("authorization", "")
    supplied = header.removeprefix("Bearer ").strip()
    expected = os.environ["API_TOKEN"]
    return {"isAuthorized": bool(supplied) and hmac.compare_digest(supplied, expected)}