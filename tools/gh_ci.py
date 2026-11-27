"""GitHub Actions 小工具：沒有 Mac、CI 是唯一的編譯器時，用來看結果、等跑完、拍截圖。

Token：環境變數 GH_TOKEN；沒有的話用 `git credential fill` 拿 github.com 的密碼（Windows 的 Git Credential Manager 會給）。
不會印出 token。

用法（在 repo 根目錄）：
  python tools/gh_ci.py runs [SHA或分支]          最近的執行（預設 HEAD 的 commit）
  python tools/gh_ci.py wait RUN_ID                 等到跑完，印出結果
  python tools/gh_ci.py notes RUN_ID                印出錯誤／警告／通知（annotations，看 CI 結果最快的方法）
  python tools/gh_ci.py log RUN_ID [關鍵字]          下載第一個 job 的 log（可只列含關鍵字的行）
  python tools/gh_ci.py rerun RUN_ID                重跑（例如 runner 沒搶到被取消）
  python tools/gh_ci.py dispatch WORKFLOW.yml REF [key=value ...]
                                                    手動觸發（只用在 Claude 可以按的流程，例如 ios-shots.yml；
                                                    上傳、上架資料、內購、CloudKit 由 Albert 按）
  python tools/gh_ci.py shots OUT_DIR [store]       把 ci-shots（或 ci-shots-store）分支的截圖取到 OUT_DIR
"""
import json
import os
import subprocess
import sys
import time
import urllib.request

REPO = "albertliuspielbery-cloud/fridge-museum"
API = f"https://api.github.com/repos/{REPO}"


def token():
    if os.environ.get("GH_TOKEN"):
        return os.environ["GH_TOKEN"]
    out = subprocess.run(["git", "credential", "fill"], input="protocol=https\nhost=github.com\n\n",
                         capture_output=True, text=True, check=True).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line[len("password="):]
    raise SystemExit("拿不到 GitHub token：設定 GH_TOKEN，或先用 git 登入 github.com")


def call(method, path, body=None, raw=False):
    req = urllib.request.Request(path if path.startswith("http") else API + path, method=method,
                                 data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"Bearer {token()}", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = r.read()
    if raw:
        return data
    return json.loads(data) if data else {}


def runs(target=None):
    target = target or subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip()
    key = "head_sha" if len(target) == 40 else "branch"
    for r in call("GET", f"/actions/runs?{key}={target}&per_page=15")["workflow_runs"]:
        print(r["id"], r["name"], r["event"], r["head_branch"], r["head_sha"][:7], r["status"], r["conclusion"],
              r["created_at"])


def wait(run_id):
    while True:
        r = call("GET", f"/actions/runs/{run_id}")
        if r["status"] == "completed":
            print(r["name"], r["conclusion"])
            return
        time.sleep(30)


def jobs(run_id):
    return call("GET", f"/actions/runs/{run_id}/jobs")["jobs"]


def notes(run_id):
    for j in jobs(run_id):
        for a in call("GET", f"/check-runs/{j['id']}/annotations"):
            print(f"[{a['annotation_level']}] {j['name']}: {a['message'].replace('%0A', chr(10))}\n")


def log(run_id, grep=None):
    text = call("GET", f"/actions/jobs/{jobs(run_id)[0]['id']}/logs", raw=True).decode("utf-8", "replace")
    for line in text.splitlines():
        if not grep or grep in line:
            print(line)


def dispatch(workflow, ref, *pairs):
    inputs = dict(p.split("=", 1) for p in pairs)
    call("POST", f"/actions/workflows/{workflow}/dispatches", {"ref": ref, "inputs": inputs})
    print("已觸發", workflow, ref, inputs)


def shots(out, store=None):
    branch = "ci-shots-store" if store else "ci-shots"
    os.makedirs(out, exist_ok=True)
    subprocess.run(["git", "fetch", "-q", "origin", branch], check=True)
    subprocess.run(["git", f"--work-tree={out}", "checkout", f"origin/{branch}", "--", "."], check=True)
    subprocess.run(["git", "reset", "-q"], check=True)
    print("截圖在", out)


if __name__ == "__main__":
    sys.stdout.reconfigure(encoding="utf-8")
    cmd, *args = sys.argv[1:] or ["help"]
    fn = {"runs": runs, "wait": wait, "notes": notes, "log": log, "dispatch": dispatch, "shots": shots,
          "rerun": lambda i: (call("POST", f"/actions/runs/{i}/rerun"), print("已重跑", i))}.get(cmd)
    if not fn:
        print(__doc__)
    else:
        fn(*args)
