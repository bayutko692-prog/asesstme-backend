#!/bin/bash
# =====================================================================
#  ASESSTME — activate the 24/7 GitHub Actions relay
#  Owner: @dvc | Builder: promode
# ---------------------------------------------------------------------
#  The workflow file lives in `workflows/relay.yml` because a classic
#  PAT without the `workflow` scope cannot create files under
#  .github/workflows/ (git refuses; the contents API answers 404).
#
#  This script copies it into place through the low-level git data API,
#  which works as soon as the token carries the `workflow` scope.
#
#  USAGE:
#     GH_TOKEN=ghp_xxxx  bash enable_actions.sh
#
#  To give a classic PAT the extra scope:
#     github.com/settings/tokens -> Edit -> add `workflow` -> save
# =====================================================================
set -euo pipefail
REPO="${REPO:-bayutko692-prog/asesstme-backend}"
TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/workflows/relay.yml"

if [ -z "$TOKEN" ]; then echo "!! set GH_TOKEN=<a PAT with the 'workflow' scope>"; exit 1; fi
if [ ! -f "$SRC" ]; then echo "!! missing $SRC"; exit 1; fi

echo "[*] checking token scopes..."
SCOPES=$(curl -s -m 20 -D - -o /dev/null https://api.github.com/user \
         -H "Authorization: token $TOKEN" | grep -i '^x-oauth-scopes' | tr -d '\r')
echo "    $SCOPES"
if ! printf '%s' "$SCOPES" | grep -qi 'workflow'; then
  echo "!! token is missing the 'workflow' scope - add it and re-run"; exit 1
fi

echo "[*] creating the workflow through the git data API..."
python3 - "$REPO" "$TOKEN" "$SRC" <<'PY'
import base64, json, sys, urllib.request, urllib.error
repo, token, src = sys.argv[1], sys.argv[2], sys.argv[3]
H = {"Authorization": "token " + token, "Accept": "application/vnd.github+json",
     "Content-Type": "application/json", "User-Agent": "asesstme"}
def req(method, url, data=None):
    r = urllib.request.Request(url, data=(json.dumps(data).encode() if data else None),
                               method=method, headers=H)
    try:
        resp = urllib.request.urlopen(r, timeout=45); t = resp.read().decode()
        return resp.status, (json.loads(t) if t.strip() else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:400]
base = "https://api.github.com/repos/" + repo
st, ref = req("GET", base + "/git/ref/heads/main"); sha = ref["object"]["sha"]
st, c = req("GET", base + "/git/commits/" + sha); tree = c["tree"]["sha"]
st, blob = req("POST", base + "/git/blobs",
    {"content": base64.b64encode(open(src,"rb").read()).decode(), "encoding": "base64"})
if st != 201: print("blob failed", st, blob); sys.exit(1)
st, t = req("POST", base + "/git/trees", {"base_tree": tree,
    "tree": [{"path": ".github/workflows/relay.yml", "mode": "100644",
              "type": "blob", "sha": blob["sha"]}]})
if st != 201: print("tree failed", st, t); sys.exit(1)
st, c2 = req("POST", base + "/git/commits",
    {"message": "ci: enable the 24/7 relay workflow", "tree": t["sha"], "parents": [sha]})
if st != 201: print("commit failed", st, c2); sys.exit(1)
st, r = req("PATCH", base + "/git/refs/heads/main", {"sha": c2["sha"], "force": False})
print("ref update:", st, r if st != 200 else "OK"); sys.exit(0 if st == 200 else 1)
PY

echo "[*] triggering the workflow..."
curl -s -m 25 -X POST "https://api.github.com/repos/$REPO/actions/workflows/relay.yml/dispatches" \
     -H "Authorization: token $TOKEN" -H "Accept: application/vnd.github+json" \
     -d '{"ref":"main","inputs":{"force":"true"}}' -o /dev/null -w "dispatch HTTP %{http_code}\n"
echo "[*] done - watch it at https://github.com/$REPO/actions"
