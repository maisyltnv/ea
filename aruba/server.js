const express = require("express");
const path = require("path");
const fs = require("fs");

const app = express();
const PORT = Number(process.env.PORT || 8082);
const HOST = process.env.HOST || "0.0.0.0";
const INDEX_FILE = path.join(__dirname, "index.html");
const LOG_FILE = path.join(__dirname, "logs.json");
const USERS_FILE = path.join(__dirname, "users.json");

// ຂໍ້ມູນ login ທີ່ຊ່ອນໄວ້ຫຼັງບ້ານ
const WIFI_USERNAME = "guest1";
const WIFI_PASSWORD = "1234";

// Local API (ເກັບຂໍ້ມູນໃນເຄື່ອງດຽວກັນ)
const SAVE_API_URL = "/api/v1/users";

app.use(express.urlencoded({ extended: true }));
app.use(express.json());

if (!fs.existsSync(LOG_FILE)) {
  fs.writeFileSync(LOG_FILE, JSON.stringify([], null, 2));
}

if (!fs.existsSync(USERS_FILE)) {
  fs.writeFileSync(USERS_FILE, JSON.stringify([], null, 2));
}

function readJson(file) {
  try {
    return JSON.parse(fs.readFileSync(file, "utf8"));
  } catch {
    return [];
  }
}

function writeJson(file, data) {
  fs.writeFileSync(file, JSON.stringify(data, null, 2));
}

function appendLog(data) {
  const logs = readJson(LOG_FILE);
  logs.push(data);
  writeJson(LOG_FILE, logs);
}

function appendUser(user) {
  const users = readJson(USERS_FILE);
  const record = {
    id: `${Date.now()}-${Math.random().toString(16).slice(2)}`,
    ...user,
    timestamp: user.timestamp || new Date().toISOString()
  };
  users.push(record);
  writeJson(USERS_FILE, users);
  return record;
}

// ໜ້າ portal
app.get("/", (req, res) => {
  res.sendFile(INDEX_FILE);
});

// Local users API (ແທນ API ພາຍນອກ)
app.post("/api/v1/users", (req, res) => {
  const { full_name, phone_number, address, mac, ip, timestamp } = req.body || {};

  if (!full_name || !phone_number) {
    return res.status(400).json({
      success: false,
      message: "ກະລຸນາປ້ອນຊື່ ແລະ ເບີໂທ"
    });
  }

  try {
    const saved = appendUser({
      full_name,
      phone_number,
      address: address || "",
      mac: mac || "",
      ip: ip || "",
      timestamp
    });
    return res.status(201).json({ success: true, data: saved });
  } catch (error) {
    return res.status(500).json({
      success: false,
      message: "Cannot save user locally: " + error.message
    });
  }
});

// Optional: ດຶງລາຍຊື່ users (ເອົາໄວ້ເຊັກ/ກວດ)
app.get("/api/v1/users", (req, res) => {
  res.json(readJson(USERS_FILE));
});

// API ບັນທຶກຂໍ້ມູນ (ຖືກເອີ້ນຈາກ frontend)
app.post("/api/save-user", async (req, res) => {
  const { full_name, phone_number, address, mac, ip } = req.body;

  console.log("📝 Save user:", { full_name, phone_number, address, mac, ip });

  if (!full_name || !phone_number) {
    return res.status(400).json({ success: false, message: "ກະລຸນາປ້ອນຊື່ ແລະ ເບີໂທ" });
  }

  try {
    const saved = appendUser({
      full_name,
      phone_number,
      address: address || "",
      mac: mac || "",
      ip: ip || "",
      timestamp: new Date().toISOString()
    });

    appendLog({
      time: new Date().toISOString(),
      full_name,
      phone_number,
      address,
      mac,
      ip,
      status: "success",
      api_response: { success: true, data: saved }
    });

    res.json({ success: true, message: "User saved successfully", data: saved });
  } catch (error) {
    console.error("Save error:", error);
    appendLog({
      time: new Date().toISOString(),
      full_name,
      phone_number,
      address,
      mac,
      ip,
      status: "error",
      error: error.message
    });
    res.status(500).json({ success: false, message: "Cannot save user locally: " + error.message });
  }
});

// ສຳລັບກວດ logs
app.get("/logs", (req, res) => {
  res.json(readJson(LOG_FILE));
});

// health check
app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    port: PORT,
    host: HOST,
    portal: `${req.protocol}://${req.get("host")}/`,
    save_api: `${req.protocol}://${req.get("host")}/api/save-user`,
    users_api: `${req.protocol}://${req.get("host")}/api/v1/users`
  });
});

app.listen(PORT, HOST, () => {
  console.log(`🚀 Server running on http://${HOST}:${PORT}`);
  console.log(`📡 Portal: http://<server-ip>:${PORT}/`);
  console.log(`📝 Save API: http://<server-ip>:${PORT}/api/save-user`);
});