import os
import uuid
import requests
from datetime import datetime, timezone
from flask import Flask, request, render_template_string
import re
import time as _time
from itertools import count

try:
    from azure.identity import DefaultAzureCredential
except ImportError:
    DefaultAzureCredential = None

app = Flask(__name__)

INFO_LOGIC_APP_URL = os.environ.get("INFO_LOGIC_APP_URL", "")
REVIEW_LOGIC_APP_URL = os.environ.get("REVIEW_LOGIC_APP_URL", "")
FEEDBACK_LOGIC_APP_URL = os.environ.get("FEEDBACK_LOGIC_APP_URL", "")

AZURE_SUBSCRIPTION_ID = os.environ.get("AZURE_SUBSCRIPTION_ID", "")
AZURE_RESOURCE_GROUP = os.environ.get("AZURE_RESOURCE_GROUP", "")
LA_NAMES = {k: os.environ.get(k, "") for k in (
    "INFO_LA_NAME", "REVIEW_LA_NAME", "FEEDBACK_LA_NAME"
)}
_VALID_RUN_ID = re.compile(r"^[A-Za-z0-9]+$")
_credential = None
_token_cache = {"token": None, "expires": 0}


def _get_mgmt_token():
    global _credential
    if not DefaultAzureCredential:
        return None
    if _token_cache["token"] and _token_cache["expires"] > _time.time() + 60:
        return _token_cache["token"]
    if _credential is None:
        _credential = DefaultAzureCredential()
    t = _credential.get_token("https://management.azure.com/.default")
    _token_cache["token"] = t.token
    _token_cache["expires"] = t.expires_on
    return t.token


def _mgmt_get(path):
    token = _get_mgmt_token()
    if not token:
        return None
    r = requests.get(
        f"https://management.azure.com{path}",
        headers={"Authorization": f"Bearer {token}"},
        timeout=10,
    )
    return r.json() if r.status_code == 200 else None


_item_seq = count(42)

DEMO_ITEMS = [
    ("Q1 Budget Report", "Document", "Finance", "$12,500", "Awaiting Q1 close figures"),
    ("Azure Migration Plan", "Proposal", "Engineering", "$85,000", "Phase 2 cloud migration"),
    ("Marketing Campaign Brief", "Document", "Marketing", "$6,200", "Summer product launch"),
    ("Vendor Contract Renewal", "Contract", "Procurement", "$34,000", "Annual SaaS license"),
    ("Security Audit Results", "Report", "InfoSec", "$0", "Quarterly compliance check"),
]

UI = """
<!DOCTYPE html>
<html>
<head><title>Workflow Notifications Demo</title>
<style>
  body { font-family: system-ui; max-width: 760px; margin: 40px auto; padding: 0 20px; color: #222; }
  h1 { font-size: 22px; margin-bottom: 4px; }
  .subtitle { color: #666; font-size: 14px; margin-bottom: 24px; }
  .scenarios { display: flex; gap: 12px; flex-wrap: wrap; }
  .scenario { flex: 1; min-width: 200px; border: 1px solid #e0e0e0; border-radius: 8px; padding: 16px; }
  .scenario h3 { margin: 0 0 6px; font-size: 14px; }
  .scenario p { margin: 0 0 12px; font-size: 12px; color: #666; }
  .scenario button { width: 100%; padding: 10px; cursor: pointer; border: none; border-radius: 4px; color: #fff; font-size: 13px; font-weight: 600; }
  .scenario button:disabled { opacity: 0.6; cursor: not-allowed; }
  .info { background: #0078d4; }
  .review { background: #d83b01; }
  .feedback { background: #107c10; }
  #result { margin-top: 20px; padding: 10px; background: #f3f3f3; white-space: pre-wrap; display: none; border-radius: 4px; font-size: 13px; }
  .section { margin-top: 30px; }
  .section h2 { font-size: 16px; margin-bottom: 8px; }
  table { width: 100%; border-collapse: collapse; font-size: 13px; }
  th, td { text-align: left; padding: 6px 8px; border-bottom: 1px solid #eee; }
  th { background: #f9f9f9; font-weight: 600; }
  .tag { display: inline-block; padding: 2px 8px; border-radius: 3px; font-size: 11px; font-weight: 600; }
  .tag-approve { background: #dff6dd; color: #107c10; }
  .tag-reject { background: #fde7e9; color: #a80000; }
  .tag-feedback { background: #e5f1fb; color: #0078d4; }
  .tag-info { background: #f3f3f3; color: #333; }
  .tag-provisioned { background: #fff4ce; color: #835c00; }
  .tag-trigger { background: #e8e8e8; color: #444; }
  .run-card { border: 1px solid #e0e0e0; border-radius: 8px; margin-bottom: 8px; }
  .run-header { display: flex; justify-content: space-between; align-items: center; flex-wrap: wrap; gap: 4px; padding: 12px 16px; cursor: pointer; }
  .run-header:hover { background: #fafafa; border-radius: 8px; }
  .run-name { font-weight: 600; font-size: 13px; }
  .run-type { font-size: 11px; color: #999; margin-left: 8px; font-family: monospace; }
  .run-corr { font-size: 11px; color: #999; margin-left: 8px; }
  .run-ago { font-size: 11px; color: #999; margin-left: 8px; }
  .run-status-succeeded { background: #dff6dd; color: #107c10; }
  .run-status-running { background: #e5f1fb; color: #0078d4; }
  .run-status-failed { background: #fde7e9; color: #a80000; }
  .run-status-cancelled { background: #f5f5f5; color: #999; }
  .pipeline { display: flex; align-items: flex-start; gap: 0; padding: 8px 16px 12px; flex-wrap: wrap; }
  .run-pipeline { display: none; border-top: 1px solid #f0f0f0; }
  .run-pipeline.open { display: block; }
  .pipe-step { display: flex; flex-direction: column; align-items: center; }
  .pipe-box { padding: 6px 10px; border-radius: 6px; font-size: 12px; border: 1px solid #ddd; background: #f9f9f9; min-width: 70px; text-align: center; line-height: 1.4; }
  .step-type { font-size: 10px; color: #888; }
  .step-dur { font-size: 10px; color: #666; margin-top: 2px; }
  .pipe-arrow { color: #ccc; font-size: 16px; padding: 0 6px; margin-top: 4px; }
  .s-succeeded { border-color: #107c10 !important; background: #dff6dd !important; }
  .s-running, .s-waiting { border-color: #0078d4 !important; background: #e5f1fb !important; }
  .s-failed { border-color: #a80000 !important; background: #fde7e9 !important; }
  .s-skipped, .s-cancelled { border-color: #999 !important; background: #f5f5f5 !important; }
  .refresh-btn { padding: 6px 14px; border: 1px solid #ddd; border-radius: 4px; background: #fff; cursor: pointer; font-size: 12px; color: #333; }
  .refresh-btn:hover { background: #f5f5f5; }
  .section-hdr { display: flex; justify-content: space-between; align-items: center; }
</style>
</head>
<body>
  <h1>Workflow Notifications Demo</h1>
  <p class="subtitle">Send workflow notifications to Microsoft Teams via Logic Apps with approval routing, conditional post-approval work, free-text feedback, and correlation-based audit trails.</p>
  <div class="scenarios">
    <div class="scenario">
      <h3>Info Notification</h3>
      <p>Fire-and-forget card with rich metadata (department, cost, comments).</p>
      <button class="info" onclick="send('info', this)">Send Info Card</button>
    </div>
    <div class="scenario">
      <h3>Approval Flow</h3>
      <p>Card with Approve/Reject buttons (Action.Submit). The Logic App suspends, waits for the response, then runs conditional post-approval work.</p>
      <button class="review" onclick="send('review', this)">Request Approval</button>
    </div>
    <div class="scenario">
      <h3>Feedback Request</h3>
      <p>Card with an inline text input. User types feedback directly in the Teams card and submits.</p>
      <button class="feedback" onclick="send('feedback', this)">Request Feedback</button>
    </div>
  </div>
  <div id="result"></div>
  <div class="section">
    <h2>Audit Trail</h2>
    <table>
      <thead><tr><th>Time</th><th>Correlation</th><th>Event</th><th>Details</th></tr></thead>
      <tbody id="audit"><tr><td colspan="4">No events yet</td></tr></tbody>
    </table>
  </div>
  <div class="section">
    <div class="section-hdr">
      <h2>Behind the Scenes</h2>
      <button class="refresh-btn" onclick="loadRuns()">Refresh</button>
    </div>
    <p class="subtitle">Logic App workflow executions. Click a run to see its actions.</p>
    <div id="runs"><p style="color:#666">Click Refresh to load runs.</p></div>
  </div>
  <script>
    async function send(type, btn) {
      btn.disabled = true;
      const origText = btn.textContent;
      btn.textContent = 'Sending...';
      const r = document.getElementById('result');
      r.style.display = 'block';
      r.textContent = 'Sending...';
      try {
        const res = await fetch('/trigger/' + type, { method: 'POST' });
        const data = await res.json();
        r.textContent = JSON.stringify(data, null, 2);
        loadAudit();
      } catch (e) { r.textContent = 'Error: ' + e.message; }
      btn.textContent = origText;
      btn.disabled = false;
    }
    const TAG_MAP = {
      info_sent: 'tag-info', review_requested: 'tag-trigger', feedback_requested: 'tag-trigger',
      approve_received: 'tag-approve', reject_received: 'tag-reject',
      post_approval_provisioned: 'tag-provisioned',
      approve: 'tag-approve', reject: 'tag-reject',
      feedback_received: 'tag-feedback'
    };
    const LABEL_MAP = {
      info_sent: 'Info Sent', review_requested: 'Review Requested', feedback_requested: 'Feedback Requested',
      approve_received: 'Approve Received', reject_received: 'Reject Received',
      post_approval_provisioned: 'Provisioned', approve: 'Approved', reject: 'Rejected',
      feedback_received: 'Feedback Received'
    };
    function tagClass(ev) { return TAG_MAP[ev] || 'tag-info'; }
    function label(ev) { return LABEL_MAP[ev] || ev; }
    async function loadAudit() {
      const res = await fetch('/audit');
      const data = await res.json();
      const tb = document.getElementById('audit');
      if (data.length === 0) { tb.innerHTML = '<tr><td colspan="4">No events yet</td></tr>'; return; }
      tb.innerHTML = data.slice().reverse().map(e =>
        '<tr><td>' + new Date(e.time).toLocaleTimeString() + '</td>'
        + '<td><code>' + e.correlationId.slice(0,8) + '</code></td>'
        + '<td><span class="tag ' + tagClass(e.event) + '">' + label(e.event) + '</span></td>'
        + '<td>' + (e.details || '') + '</td></tr>'
      ).join('');
    }
    loadAudit();
    setInterval(loadAudit, 5000);
    const WF_LABELS={info:'Info Notification',review:'Approval Flow',decision:'Decision (Post-Approval)',feedback:'Feedback Request'};
    const ACT_TYPES={Response:'HTTP Response',ApiConnection:'Teams Connector',ApiConnectionWebhook:'Teams Webhook (waits)',Http:'HTTP Callback',If:'Condition'};
    function timeAgo(s){if(!s)return'';const d=(Date.now()-new Date(s).getTime())/1000;if(d<5)return'just now';if(d<60)return Math.round(d)+'s ago';if(d<3600)return Math.round(d/60)+'m ago';return Math.round(d/3600)+'h ago';}
    function calcDur(a,b){if(!a||!b)return'';const m=new Date(b)-new Date(a);return m<1000?m+'ms':(m/1000).toFixed(1)+'s';}
    async function loadRuns(){
      try{
        const btn=document.querySelector('.refresh-btn');if(btn){btn.disabled=true;btn.textContent='Loading...';}
        const res=await fetch('/api/runs');const data=await res.json();
        const el=document.getElementById('runs');
        if(btn){btn.disabled=false;btn.textContent='Refresh';}
        if(!data.length){el.innerHTML='<p style="color:#666">No runs yet. Trigger a scenario above.</p>';return;}
        el.innerHTML=data.map((r,i)=>{
          const wl=WF_LABELS[r.type]||r.type;
          const sc=r.status.toLowerCase();
          const cs=(r.correlationId||'').slice(0,8);
          return '<div class="run-card"><div class="run-header" onclick="toggleRun('+i+',\\''+r.workflow+'\\',\\''+r.runId+'\\')"><div><span class="run-name">'+wl+'</span><span class="run-type">'+r.workflow+'</span>'+(cs?' <code class="run-corr">'+cs+'</code>':'')+'</div><div><span class="tag run-status-'+sc+'">'+r.status+'</span><span class="run-ago">'+timeAgo(r.startTime)+'</span></div></div><div class="run-pipeline" id="pl-'+i+'"></div></div>';
        }).join('');
      }catch(e){document.getElementById('runs').innerHTML='<p style="color:#999">Could not load runs.</p>';}
    }
    async function toggleRun(idx,wf,rid){
      const el=document.getElementById('pl-'+idx);if(!el)return;
      if(el.classList.contains('open')){el.classList.remove('open');return;}
      if(!el.dataset.loaded){
        el.innerHTML='<div style="padding:8px 16px;color:#999;font-size:11px">loading...</div>';
        el.classList.add('open');
        try{
          const res=await fetch('/api/runs/'+encodeURIComponent(wf)+'/'+encodeURIComponent(rid)+'/actions');
          const acts=await res.json();
          if(!acts.length){el.innerHTML='<div style="padding:8px 16px;color:#999;font-size:12px">No actions</div>';}
          else{el.innerHTML='<div class="pipeline">'+acts.map((a,i)=>{
            const sc='s-'+a.status.toLowerCase();
            const tl=ACT_TYPES[a.type]||a.type||'';
            const d=a.status==='Waiting'?'waiting\u2026':calcDur(a.startTime,a.endTime);
            return (i>0?'<span class="pipe-arrow">\u2192</span>':'')+'<div class="pipe-step"><div class="pipe-box '+sc+'"><div>'+a.name.replace(/_/g,' ')+'</div>'+(tl?'<div class="step-type">'+tl+'</div>':'')+'</div>'+(d?'<div class="step-dur">'+d+'</div>':'')+'</div>';
          }).join('')+'</div>';}
          el.dataset.loaded='1';
        }catch(e){el.innerHTML='<div style="padding:8px 16px;color:#999;font-size:12px">Failed to load</div>';}
      }else{el.classList.add('open');}
    }
  </script>
</body>
</html>
"""

# In-memory audit log (demo only)
audit_log = []


def add_audit(correlation_id, event, details=""):
    audit_log.append({
        "correlationId": correlation_id,
        "event": event,
        "details": details,
        "time": datetime.now(timezone.utc).isoformat(),
    })


def next_item():
    seq = next(_item_seq)
    item = DEMO_ITEMS[seq % len(DEMO_ITEMS)]
    return {
        "itemId": f"ITEM-{seq}",
        "itemName": item[0],
        "itemType": item[1],
        "department": item[2],
        "estimatedCost": item[3],
        "comments": item[4],
    }


@app.route("/")
def index():
    return render_template_string(UI)


@app.route("/trigger/info", methods=["POST"])
def trigger_info():
    if not INFO_LOGIC_APP_URL:
        return {"error": "INFO_LOGIC_APP_URL not configured"}, 500
    correlation_id = str(uuid.uuid4())
    item = next_item()
    payload = {
        "eventType": "item_created",
        "submittedBy": "demo-user@example.com",
        "currentStage": "Draft",
        "correlationId": correlation_id,
        **item,
    }
    add_audit(correlation_id, "info_sent", f"Info card for {item['itemName']}")
    r = requests.post(
        INFO_LOGIC_APP_URL,
        json=payload,
        headers={"x-ms-client-tracking-id": correlation_id},
        timeout=10,
    )
    return {"status": r.status_code, "correlationId": correlation_id, "message": "Info notification sent"}


@app.route("/trigger/review", methods=["POST"])
def trigger_review():
    if not REVIEW_LOGIC_APP_URL:
        return {"error": "REVIEW_LOGIC_APP_URL not configured"}, 500
    correlation_id = str(uuid.uuid4())
    item = next_item()
    payload = {
        "eventType": "review_requested",
        "submittedBy": "demo-user@example.com",
        "currentStage": "Pending Review",
        "priority": "High",
        "correlationId": correlation_id,
        **item,
    }
    add_audit(correlation_id, "review_requested", f"Approval requested for {item['itemName']}")
    r = requests.post(
        REVIEW_LOGIC_APP_URL,
        json=payload,
        headers={"x-ms-client-tracking-id": correlation_id},
        timeout=10,
    )
    return {"status": r.status_code, "correlationId": correlation_id, "message": "Review request sent"}


@app.route("/trigger/feedback", methods=["POST"])
def trigger_feedback():
    if not FEEDBACK_LOGIC_APP_URL:
        return {"error": "FEEDBACK_LOGIC_APP_URL not configured"}, 500
    correlation_id = str(uuid.uuid4())
    item = next_item()
    payload = {
        "eventType": "feedback_requested",
        "submittedBy": "demo-user@example.com",
        "correlationId": correlation_id,
        **item,
    }
    add_audit(correlation_id, "feedback_requested", f"Feedback requested for {item['itemName']}")
    r = requests.post(
        FEEDBACK_LOGIC_APP_URL,
        json=payload,
        headers={"x-ms-client-tracking-id": correlation_id},
        timeout=10,
    )
    return {"status": r.status_code, "correlationId": correlation_id, "message": "Feedback request sent"}


@app.route("/callback/review", methods=["POST"])
def callback_review():
    """Receives approve/reject callback from the Review Logic App after webhook wait."""
    data = request.get_json(silent=True) or {}
    action = data.get("action", "unknown")
    item_id = data.get("itemId", "unknown")
    item_name = data.get("itemName", "unknown")
    correlation_id = data.get("correlationId", "unknown")
    provisioned = data.get("provisioned", False)
    add_audit(correlation_id, f"{action}_received", f"Decision received for {item_name}")
    if provisioned:
        add_audit(correlation_id, "post_approval_provisioned", f"Logic App provisioned resources for {item_id}")
    add_audit(correlation_id, action, f"{action}d {item_id}")
    print(f"REVIEW: {item_id} corr={correlation_id} action={action} provisioned={provisioned}", flush=True)
    return {"status": "received", "correlationId": correlation_id}


@app.route("/callback/feedback", methods=["POST"])
def callback_feedback():
    data = request.get_json(silent=True) or {}
    item_id = data.get("itemId", "unknown")
    correlation_id = data.get("correlationId", "unknown")
    feedback_text = data.get("feedback", "")
    print(f"FEEDBACK: {item_id} corr={correlation_id} text={feedback_text}", flush=True)
    add_audit(correlation_id, "feedback_received", f"Feedback on {item_id}: {feedback_text[:80]}")
    return {"status": "received", "correlationId": correlation_id}


@app.route("/api/runs")
def api_runs():
    if not AZURE_SUBSCRIPTION_ID or not AZURE_RESOURCE_GROUP:
        return []
    base = (f"/subscriptions/{AZURE_SUBSCRIPTION_ID}/resourceGroups/{AZURE_RESOURCE_GROUP}"
            f"/providers/Microsoft.Logic/workflows")
    all_runs = []
    for env_key, la_name in LA_NAMES.items():
        if not la_name:
            continue
        wf_type = env_key.replace("_LA_NAME", "").lower()
        data = _mgmt_get(f"{base}/{la_name}/runs?$top=3&api-version=2019-05-01")
        if not data:
            continue
        for run in data.get("value", []):
            props = run["properties"]
            all_runs.append({
                "workflow": la_name,
                "type": wf_type,
                "runId": run["name"],
                "status": props["status"],
                "startTime": props.get("startTime", ""),
                "endTime": props.get("endTime", ""),
                "correlationId": props.get("correlation", {}).get("clientTrackingId", ""),
            })
    all_runs.sort(key=lambda x: x.get("startTime", ""), reverse=True)
    return all_runs[:15]


_wf_action_types = {}  # cache: workflow_name -> {action_name: type}


def _get_action_types(workflow):
    if workflow not in _wf_action_types:
        base = (f"/subscriptions/{AZURE_SUBSCRIPTION_ID}/resourceGroups/{AZURE_RESOURCE_GROUP}"
                f"/providers/Microsoft.Logic/workflows")
        wf = _mgmt_get(f"{base}/{workflow}?api-version=2019-05-01")
        if wf:
            acts = wf.get("properties", {}).get("definition", {}).get("actions", {})
            types = {n: a.get("type", "") for n, a in acts.items()}
            if types:
                _wf_action_types[workflow] = types
    return _wf_action_types.get(workflow, {})


@app.route("/api/runs/<workflow>/<run_id>/actions")
def api_run_actions(workflow, run_id):
    allowed = set(v for v in LA_NAMES.values() if v)
    if workflow not in allowed:
        return {"error": "Invalid workflow"}, 400
    if not _VALID_RUN_ID.match(run_id):
        return {"error": "Invalid run ID"}, 400
    base = (f"/subscriptions/{AZURE_SUBSCRIPTION_ID}/resourceGroups/{AZURE_RESOURCE_GROUP}"
            f"/providers/Microsoft.Logic/workflows")
    data = _mgmt_get(f"{base}/{workflow}/runs/{run_id}/actions?api-version=2019-05-01")
    if not data:
        return []
    type_map = _get_action_types(workflow)
    actions = []
    for a in data.get("value", []):
        p = a["properties"]
        actions.append({
            "name": a["name"],
            "type": type_map.get(a["name"], p.get("type", "")),
            "status": p["status"],
            "startTime": p.get("startTime", ""),
            "endTime": p.get("endTime", ""),
        })
    actions.sort(key=lambda x: x.get("startTime", ""))
    return actions


@app.route("/audit")
def get_audit():
    return audit_log


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
