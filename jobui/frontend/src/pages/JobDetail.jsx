import { useEffect, useState } from "react";
import { useParams, Link } from "react-router-dom";
import { api } from "../api.js";

export default function JobDetail() {
  const { id } = useParams();
  const [job, setJob] = useState(null);
  const [err, setErr] = useState("");

  useEffect(() => {
    const load = () =>
      api.get("/api/jobs/" + id).then(setJob).catch((e) => setErr(e.message));
    load();
    const t = setInterval(load, 5000);
    return () => clearInterval(t);
  }, [id]);

  async function cancel() {
    if (!confirm("cancel this job?")) return;
    await api.post("/api/jobs/" + id + "/cancel");
  }

  if (err) return <div className="mono text-red-600">{err}</div>;
  if (!job) return <div className="mono">loading...</div>;

  const inProgress = ["submitted", "pending", "running"].includes(job.status);

  return (
    <div>
      <div className="flex items-start justify-between mb-8">
        <div>
          <Link to="/jobs" className="mono text-xs text-muted hover:underline">
            ← jobs
          </Link>
          <h1 className="text-3xl mono font-bold tracking-tight mt-1">
            job #{job.id}
          </h1>
          <div className="mono text-xs text-muted mt-1">
            slurm {job.slurm_job_id} · {job.partition}
          </div>
        </div>
        {inProgress && (
          <button onClick={cancel} className="btn-ghost btn">
            cancel
          </button>
        )}
      </div>

      <div className="grid md:grid-cols-3 gap-6 mb-6">
        <div className="card">
          <div className="text-xs text-muted mono mb-1">status</div>
          <div className="mono font-bold">{job.status}</div>
          {job.slurm_state && (
            <div className="text-xs text-muted mt-1">slurm: {job.slurm_state}</div>
          )}
          {job.slurm_reason && (
            <div className="text-xs text-muted">{job.slurm_reason}</div>
          )}
        </div>
        <div className="card">
          <div className="text-xs text-muted mono mb-1">cost</div>
          <div className="mono font-bold">
            ${Number(job.actual_cost_usd || job.estimated_cost_usd).toFixed(2)}
          </div>
          <div className="text-xs text-muted mt-1">
            {job.actual_cost_usd ? "final" : "estimated"}
          </div>
        </div>
        <div className="card">
          <div className="text-xs text-muted mono mb-1">gpu</div>
          <div className="mono font-bold">{job.gpu_family}</div>
          {job.slurm_node && (
            <div className="text-xs text-muted mt-1">on {job.slurm_node}</div>
          )}
        </div>
      </div>

      {job.result_files && job.result_files.length > 0 && (
        <div className="card mb-6">
          <h2 className="mono font-bold mb-3">results</h2>
          <ul className="divide-y divide-border">
            {job.result_files.map((f) => (
              <li key={f.key} className="py-2 flex justify-between items-center">
                <span className="mono text-sm truncate">{f.key}</span>
                <a href={f.url} className="btn-ghost btn text-xs py-1" download>
                  download
                </a>
              </li>
            ))}
          </ul>
        </div>
      )}

      <div className="card">
        <h2 className="mono font-bold mb-3">log</h2>
        <pre className="text-xs mono bg-ink text-paper p-4 overflow-auto max-h-96 whitespace-pre-wrap">
{job.log_tail || "(no log yet)"}
        </pre>
      </div>
    </div>
  );
}
