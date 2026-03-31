import os
import requests
from datetime import datetime, timezone
from flask import Flask, request, render_template_string

app = Flask(__name__)

INFO_LOGIC_APP_URL = os.environ.get("INFO_LOGIC_APP_URL", "")
REVIEW_LOGIC_APP_URL = os.environ.get("REVIEW_LOGIC_APP_URL", "")

UI = """
<!DOCTYPE html>
<html>
<head><title>Workflow Notifications Demo</title>
<style>
  body { font-family: system-ui; max-width: 600px; margin: 40px auto; padding: 0 20px; }
  button { padding: 10px 20px; margin: 5px; cursor: pointer; border: none; border-radius: 4px; color: #fff; font-size: 14px; }
  .info { background: #0078d4; }
  .review { background: #d83b01; }
  #result { margin-top: 20px; padding: 10px; background: #f3f3f3; white-space: pre-wrap; display: none; border-radius: 4px; }
  h1 { font-size: 22px; }
  .decisions { margin-top: 30px; }
  .decisions h2 { font-size: 16px; }
  .decisions ul { list-style: none; padding: 0; }
  .decisions li { padding: 6px 0; border-bottom: 1px solid #eee; }
</style>
</head>
<body>
  <h1>Workflow Notifications Demo</h1>
  <p>Send notifications to Microsoft Teams via Logic Apps.</p>
  <button class="info" onclick="send('info')">Send Info Notification</button>
  <button class="review" onclick="send('review')">Request Approval</button>
  <div id="result"></div>
  <div class="decisions">
    <h2>Decisions received</h2>
    <ul id="decisions"><li>None yet</li></ul>
  </div>
  <script>
    async function send(type) {
      const r = document.getElementById('result');
      r.style.display = 'block';
      r.textContent = 'Sending...';
      try {
        const res = await fetch('/trigger/' + type, { method: 'POST' });
        const data = await res.json();
        r.textContent = JSON.stringify(data, null, 2);
      } catch (e) { r.textContent = 'Error: ' + e.message; }
    }
    async function loadDecisions() {
      const res = await fetch('/decisions');
      const data = await res.json();
      const ul = document.getElementById('decisions');
      if (data.length === 0) { ul.innerHTML = '<li>None yet</li>'; return; }
      ul.innerHTML = data.map(d => '<li><b>' + d.action + '</b> on item ' + d.itemId + ' at ' + d.time + '</li>').join('');
    }
    loadDecisions();
    setInterval(loadDecisions, 5000);
  </script>
</body>
</html>
"""

# In-memory log of decisions (demo only)
decisions = []


@app.route("/")
def index():
    return render_template_string(UI)


@app.route("/trigger/info", methods=["POST"])
def trigger_info():
    if not INFO_LOGIC_APP_URL:
        return {"error": "INFO_LOGIC_APP_URL not configured"}, 500
    payload = {
        "eventType": "item_created",
        "itemId": "ITEM-42",
        "itemName": "Q1 Budget Report",
        "itemType": "Document",
        "submittedBy": "demo-user@example.com",
        "currentStage": "Draft",
        "itemDetailUrl": "https://example.com/items/42",
    }
    r = requests.post(INFO_LOGIC_APP_URL, json=payload, timeout=10)
    return {"status": r.status_code, "message": "Info notification sent"}


@app.route("/trigger/review", methods=["POST"])
def trigger_review():
    if not REVIEW_LOGIC_APP_URL:
        return {"error": "REVIEW_LOGIC_APP_URL not configured"}, 500
    payload = {
        "eventType": "review_requested",
        "itemId": "ITEM-42",
        "itemName": "Q1 Budget Report",
        "itemType": "Document",
        "submittedBy": "demo-user@example.com",
        "currentStage": "Pending Review",
        "priority": "High",
        "itemDetailUrl": "https://example.com/items/42",
    }
    r = requests.post(REVIEW_LOGIC_APP_URL, json=payload, timeout=10)
    return {"status": r.status_code, "message": "Review request sent"}


@app.route("/callback")
def callback():
    action = request.args.get("action", "unknown")
    item_id = request.args.get("itemId", "unknown")
    print(f"DECISION: {action} on {item_id}", flush=True)
    decisions.append({"action": action, "itemId": item_id, "time": datetime.now(timezone.utc).isoformat()})
    return f"""<html><body style="font-family:system-ui;text-align:center;padding:40px">
    <h2>{'Approved' if action == 'approve' else 'Rejected'}</h2>
    <p>Item <b>{item_id}</b> has been <b>{action}d</b>.</p>
    <p>You can close this tab.</p></body></html>"""


@app.route("/decisions")
def get_decisions():
    return decisions


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
