import { useEffect, useState } from "react";
import { api } from "../api.js";

export default function Admin() {
  const [tab, setTab] = useState("users");
  return (
    <div>
      <h1 className="text-3xl mono font-bold tracking-tight mb-8">admin</h1>
      <div className="flex gap-2 mb-6">
        {["users", "models"].map((t) => (
          <button
            key={t}
            onClick={() => setTab(t)}
            className={
              "px-4 py-2 mono text-sm border " +
              (tab === t ? "border-ink bg-ink text-paper" : "border-border")
            }
          >
            {t}
          </button>
        ))}
      </div>
      {tab === "users" ? <UsersAdmin /> : <ModelsAdmin />}
    </div>
  );
}

function UsersAdmin() {
  const [users, setUsers] = useState([]);
  const [busy, setBusy] = useState(false);
  const [showForm, setShowForm] = useState(false);

  const load = () => api.get("/api/users").then(setUsers);
  useEffect(() => { load(); }, []);

  async function toggleH100(u) {
    setBusy(true);
    try {
      await api.patch("/api/users/" + u.id, { h100_approved: !u.h100_approved });
      await load();
    } finally { setBusy(false); }
  }

  async function toggleActive(u) {
    setBusy(true);
    try {
      await api.patch("/api/users/" + u.id, { is_active: !u.is_active });
      await load();
    } finally { setBusy(false); }
  }

  return (
    <div>
      <div className="flex justify-end mb-4">
        <button className="btn btn-primary" onClick={() => setShowForm(!showForm)}>
          {showForm ? "cancel" : "+ add user"}
        </button>
      </div>

      {showForm && <AddUserForm onDone={() => { setShowForm(false); load(); }} />}

      <div className="border border-border">
        <table className="w-full text-sm">
          <thead className="bg-ink text-paper">
            <tr className="mono text-xs text-left">
              <th className="p-3">username</th>
              <th className="p-3">email</th>
              <th className="p-3">role</th>
              <th className="p-3">h100</th>
              <th className="p-3 text-right">budget</th>
              <th className="p-3">active</th>
            </tr>
          </thead>
          <tbody>
            {users.map((u) => (
              <tr key={u.id} className="border-t border-border">
                <td className="p-3 mono">{u.username}</td>
                <td className="p-3 text-muted">{u.email}</td>
                <td className="p-3 mono text-xs">{u.role}</td>
                <td className="p-3">
                  <button
                    disabled={busy}
                    onClick={() => toggleH100(u)}
                    className={"pill " + (u.h100_approved ? "bg-accent" : "bg-border")}
                  >
                    {u.h100_approved ? "✓ approved" : "denied"}
                  </button>
                </td>
                <td className="p-3 mono text-right">
                  ${Number(u.monthly_budget_usd).toFixed(0)}/mo
                </td>
                <td className="p-3">
                  <button
                    disabled={busy}
                    onClick={() => toggleActive(u)}
                    className={"pill " + (u.is_active ? "bg-green-100" : "bg-red-100")}
                  >
                    {u.is_active ? "active" : "disabled"}
                  </button>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

function AddUserForm({ onDone }) {
  const [form, setForm] = useState({
    username: "",
    email: "",
    display_name: "",
    role: "member",
    h100_approved: false,
    monthly_budget_usd: 500,
    temp_password: "",
  });
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      await api.post("/api/users", form);
      onDone();
    } catch (e) {
      setErr(e.message);
    } finally {
      setBusy(false);
    }
  }

  const set = (k, v) => setForm({ ...form, [k]: v });

  return (
    <form onSubmit={submit} className="card mb-4 space-y-3">
      <div className="grid grid-cols-2 gap-3">
        <input className="input" placeholder="username" value={form.username}
          onChange={(e) => set("username", e.target.value)} />
        <input className="input" placeholder="email" type="email" value={form.email}
          onChange={(e) => set("email", e.target.value)} />
        <input className="input" placeholder="display name" value={form.display_name}
          onChange={(e) => set("display_name", e.target.value)} />
        <select className="input" value={form.role} onChange={(e) => set("role", e.target.value)}>
          <option>member</option>
          <option>admin</option>
        </select>
        <input className="input" type="number" min={50} step={50}
          value={form.monthly_budget_usd}
          onChange={(e) => set("monthly_budget_usd", parseFloat(e.target.value))} />
        <input className="input" type="password" placeholder="temp password (min 12)"
          value={form.temp_password}
          onChange={(e) => set("temp_password", e.target.value)} />
      </div>
      <label className="flex items-center gap-2 text-sm">
        <input type="checkbox" checked={form.h100_approved}
          onChange={(e) => set("h100_approved", e.target.checked)} />
        h100 approved
      </label>
      {err && <div className="text-red-600 text-sm mono">{err}</div>}
      <button type="submit" disabled={busy} className="btn btn-primary">
        {busy ? "creating..." : "create user"}
      </button>
    </form>
  );
}

function ModelsAdmin() {
  const [models, setModels] = useState([]);
  const [showForm, setShowForm] = useState(false);

  const load = () => api.get("/api/models").then(setModels);
  useEffect(() => { load(); }, []);

  async function deactivate(id) {
    if (!confirm("deactivate this model?")) return;
    await api.delete("/api/models/" + id);
    await load();
  }

  return (
    <div>
      <div className="flex justify-end mb-4">
        <button className="btn btn-primary" onClick={() => setShowForm(!showForm)}>
          {showForm ? "cancel" : "+ register model"}
        </button>
      </div>
      {showForm && <AddModelForm onDone={() => { setShowForm(false); load(); }} />}
      <div className="space-y-3">
        {models.map((m) => (
          <div key={m.id} className="card flex items-start justify-between gap-4">
            <div className="flex-1">
              <div className="flex items-center gap-3">
                <span className="mono font-bold">{m.display_name}</span>
                <span className="pill">{m.model_key}</span>
                <span className="text-xs text-muted mono">{m.gpu_min_memory_gb}GB min</span>
              </div>
              <div className="mono text-xs text-muted mt-1">{m.ecr_uri}</div>
              {m.description && <div className="text-sm mt-2">{m.description}</div>}
              <div className="mt-2 flex gap-2">
                {m.allowed_gpus.map((g) => <span key={g} className="pill">{g}</span>)}
              </div>
            </div>
            <button className="btn-ghost btn text-xs py-1" onClick={() => deactivate(m.id)}>
              deactivate
            </button>
          </div>
        ))}
        {models.length === 0 && (
          <div className="text-muted text-sm">no models registered yet</div>
        )}
      </div>
    </div>
  );
}

function AddModelForm({ onDone }) {
  const [form, setForm] = useState({
    model_key: "",
    display_name: "",
    description: "",
    ecr_uri: "",
    weights_path: "",
    gpu_min_memory_gb: 16,
    allowed_gpus: ["t4", "a10g"],
    default_runtime_hours: 4,
    max_runtime_hours: 24,
  });
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const set = (k, v) => setForm({ ...form, [k]: v });

  async function submit(e) {
    e.preventDefault();
    setBusy(true);
    setErr("");
    try {
      await api.post("/api/models", form);
      onDone();
    } catch (e) { setErr(e.message); }
    finally { setBusy(false); }
  }

  function toggleGpu(g) {
    const next = form.allowed_gpus.includes(g)
      ? form.allowed_gpus.filter((x) => x !== g)
      : [...form.allowed_gpus, g];
    set("allowed_gpus", next);
  }

  return (
    <form onSubmit={submit} className="card mb-4 space-y-3">
      <div className="grid grid-cols-2 gap-3">
        <input className="input" placeholder="model_key (e.g. evo2-7b-v1)"
          value={form.model_key} onChange={(e) => set("model_key", e.target.value)} />
        <input className="input" placeholder="display name"
          value={form.display_name} onChange={(e) => set("display_name", e.target.value)} />
      </div>
      <input className="input" placeholder="ecr uri (full)"
        value={form.ecr_uri} onChange={(e) => set("ecr_uri", e.target.value)} />
      <input className="input" placeholder="weights path (optional, /fsx/models/...)"
        value={form.weights_path} onChange={(e) => set("weights_path", e.target.value)} />
      <textarea className="input" placeholder="description"
        value={form.description} onChange={(e) => set("description", e.target.value)} />
      <div className="grid grid-cols-3 gap-3">
        <input className="input" type="number" placeholder="min GPU memory (GB)"
          value={form.gpu_min_memory_gb}
          onChange={(e) => set("gpu_min_memory_gb", parseInt(e.target.value))} />
        <input className="input" type="number" placeholder="default runtime hours"
          value={form.default_runtime_hours}
          onChange={(e) => set("default_runtime_hours", parseInt(e.target.value))} />
        <input className="input" type="number" placeholder="max runtime hours"
          value={form.max_runtime_hours}
          onChange={(e) => set("max_runtime_hours", parseInt(e.target.value))} />
      </div>
      <div>
        <div className="text-xs mono mb-2">allowed GPUs</div>
        <div className="flex gap-2 flex-wrap">
          {["t4", "a10g", "l4", "a100", "h100-1x", "h100-8x"].map((g) => (
            <button type="button" key={g} onClick={() => toggleGpu(g)}
              className={"pill " + (form.allowed_gpus.includes(g) ? "bg-accent" : "")}>
              {g}
            </button>
          ))}
        </div>
      </div>
      {err && <div className="text-red-600 text-sm mono">{err}</div>}
      <button type="submit" disabled={busy} className="btn btn-primary">
        {busy ? "registering..." : "register model"}
      </button>
    </form>
  );
}
