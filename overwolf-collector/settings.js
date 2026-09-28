const endpointInput = document.getElementById("endpoint");
const tokenInput = document.getElementById("token");
const status = document.getElementById("status");

endpointInput.value = localStorage.getItem("ow_cloud_endpoint") || "";
tokenInput.value = localStorage.getItem("ow_cloud_token") || "";

document.getElementById("save").addEventListener("click", async () => {
  const endpoint = endpointInput.value.trim();
  const token = tokenInput.value.trim();

  if (!endpoint || !token) {
    status.textContent = "URLとトークンの両方が必要です。";
    return;
  }

  localStorage.setItem("ow_cloud_endpoint", endpoint);
  localStorage.setItem("ow_cloud_token", token);
  status.textContent = "保存しました。診断送信をテストしています…";

  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${token}`
      },
      body: JSON.stringify({
        kind: "diagnostic_snapshot",
        received_at: new Date().toISOString(),
        session_id: "setup-test",
        diagnostic: {
          event_counts: { setup_test: 1 },
          schema_by_event: { setup_test: { kind: "string" } }
        }
      })
    });

    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    status.textContent = "接続成功。以後はOW2起動時に自動収集します。";
  } catch (error) {
    status.textContent = `接続失敗: ${error.message}`;
  }
});
