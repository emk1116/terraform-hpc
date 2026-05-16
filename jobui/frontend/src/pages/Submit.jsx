import { useEffect, useMemo, useState } from "react";
import { useNavigate } from "react-router-dom";
import { api, uploadFileMultipart } from "../api.js";
import { useAuth } from "../auth.jsx";

function fmtSize(bytes) {
  if (bytes < 1024) return bytes + " B";
  if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
  if (bytes < 1024 * 1024 * 1024) return (bytes / 1024 / 1024).toFixed(1) + " MB";
  return (bytes / 1024 / 1024 / 1024).toFixed(2) + " GB";
}

export default function Submit() {
  const { user } = useAuth();
  const navigate = useNavigate();

  // Step state
  const [file, setFile] = useState(null);
  const [uploadId, setUploadId] = useState(null);
  const [uploadProgress, setUploadProgress] = useState(0);
  const [uploading, setUploading] = useState(false);
  const [uploadErr, setUploadErr] = useState("");

  // Catalogs
  const [gpus, setGpus] = useState([]);
  const [models, setModels] = useState([]);
  const [gpuFamily, setGpuFamily] = useState("");
  const [modelId, setModelId] = useState("");
  const [hours, setHours] = useState(4);

  // Cost preview
  const [preview, setPreview] = useState(null);
  const [submitting, setSubmitting] = useState(false);
  const [submitErr, setSubmitErr] = useState("");

  useEffect(() => {
    api.get("/api/gpus").then(setGpus).catch((e) => setSubmitErr(e.message));
  }, []);

  // Models dropdown — refetch when GPU family changes so we only show compatible
  useEffect(() => {
    if (!gpuFamily) {
      api.get("/api/models").then(setModels);
      return;
    }
    api.get("/api/models?gpu_family=" + encodeURIComponent(gpuFamily)).then(setModels);
    setModelId("");
  }, [gpuFamily]);

  // Cost preview — refetch when gpu or hours change
  useEffect(() => {
    if (!gpuFamily || !hours) return setPreview(null);
    api
      .post("/api/gpus/cost-preview", { gpu_family: gpuFamily, hours })
      .then(setPreview)
      .catch(() => setPreview(null));
  }, [gpuFamily, hours]);

  const selectedModel = useMemo(
    () => models.find((m) => m.id === parseInt(modelId)),
    [models, modelId],
  );
  const selectedGpu = useMemo(
    () => gpus.find((g) => g.family === gpuFamily),
    [gpus, gpuFamily],
  );

  async function doUpload(f) {
    setFile(f);
    setUploading(true);
    setUploadErr("");
    setUploadProgress(0);
    setUploadId(null);
    try {
      const result = await uploadFileMultipart(f, (p) => setUploadProgress(p));
      setUploadId(result.upload_id);
    } catch (e) {
      setUploadErr(e.message);
      setFile(null);
    } finally {
      setUploading(false);
    }
  }

  async function submit() {
    if (!uploadId || !gpuFamily || !modelId) return;
    setSubmitting(true);
    setSubmitErr("");
    try {
      const job = await api.post("/api/jobs", {
        upload_id: uploadId,
        model_id: parseInt(modelId),
        gpu_family: gpuFamily,
        gpu_count: 1,
        requested_hours: parseInt(hours),
      });
      navigate("/jobs/" + job.job_id);
    } catch (e) {
      setSubmitErr(e.message);
    } finally {
      setSubmitting(false);
    }
  }

  const canSubmit =
    uploadId && gpuFamily && modelId && hours > 0 && !preview?.will_exceed_budget;

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-3xl mono font-bold tracking-tight">submit job</h1>
        <p className="text-muted mt-1">
          Upload input, pick a GPU and a model. Cost is estimated before you submit.
        </p>
      </div>

      <div className="grid md:grid-cols-3 gap-6">
        <div className="md:col-span-2 space-y-6">
          {/* Step 1 — Upload */}
          <div className="card">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-6 h-6 bg-ink text-paper flex items-center justify-center mono text-xs">1</div>
              <h2 className="mono font-bold">input file</h2>
            </div>

            {!file && (
              <label className="block border-2 border-dashed border-border hover:border-ink transition p-8 text-center cursor-pointer">
                <input
                  type="file"
                  className="hidden"
                  onChange={(e) => e.target.files[0] && doUpload(e.target.files[0])}
                />
                <div className="mono text-sm">drop file or click to select</div>
                <div className="text-xs text-muted mt-2">
                  up to 10 GB; uploads directly to S3 in parallel chunks
                </div>
              </label>
            )}

            {file && (
              <div className="space-y-3">
                <div className="flex justify-between items-start">
                  <div>
                    <div className="mono font-medium">{file.name}</div>
                    <div className="text-xs text-muted">{fmtSize(file.size)}</div>
                  </div>
                  {!uploading && uploadId && (
                    <button
                      className="btn-ghost btn text-xs py-1"
                      onClick={() => { setFile(null); setUploadId(null); }}
                    >
                      change
                    </button>
                  )}
                </div>

                {uploading && (
                  <div>
                    <div className="h-2 bg-border overflow-hidden">
                      <div
                        className="h-2 bg-accent transition-all"
                        style={{ width: (uploadProgress * 100).toFixed(1) + "%" }}
                      />
                    </div>
                    <div className="text-xs text-muted mt-1 mono">
                      uploading... {(uploadProgress * 100).toFixed(0)}%
                    </div>
                  </div>
                )}

                {!uploading && uploadId && (
                  <div className="text-xs mono text-green-700">
                    ✓ uploaded to s3
                  </div>
                )}

                {uploadErr && (
                  <div className="text-xs mono text-red-600">{uploadErr}</div>
                )}
              </div>
            )}
          </div>

          {/* Step 2 — GPU */}
          <div className="card">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-6 h-6 bg-ink text-paper flex items-center justify-center mono text-xs">2</div>
              <h2 className="mono font-bold">gpu</h2>
            </div>
            <div className="grid sm:grid-cols-2 gap-3">
              {gpus.map((g) => (
                <button
                  key={g.family}
                  onClick={() => setGpuFamily(g.family)}
                  className={
                    "text-left p-4 border transition " +
                    (gpuFamily === g.family
                      ? "border-ink bg-ink text-paper"
                      : "border-border hover:border-ink")
                  }
                >
                  <div className="mono font-bold">{g.display_name}</div>
                  <div className="text-xs opacity-75 mt-1">{g.instance_type}</div>
                  <div className="text-xs mono mt-2">
                    ${g.hourly_cost_usd.toFixed(2)}/hr
                  </div>
                </button>
              ))}
            </div>
          </div>

          {/* Step 3 — Model */}
          <div className="card">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-6 h-6 bg-ink text-paper flex items-center justify-center mono text-xs">3</div>
              <h2 className="mono font-bold">model</h2>
            </div>
            {!gpuFamily && (
              <div className="text-sm text-muted">pick a GPU first</div>
            )}
            {gpuFamily && models.length === 0 && (
              <div className="text-sm text-muted">
                no models registered yet for {gpuFamily}. An admin needs to register one.
              </div>
            )}
            {gpuFamily && models.length > 0 && (
              <select
                className="input"
                value={modelId}
                onChange={(e) => setModelId(e.target.value)}
              >
                <option value="">— select a model —</option>
                {models.map((m) => (
                  <option key={m.id} value={m.id}>
                    {m.display_name} ({m.gpu_min_memory_gb} GB min)
                  </option>
                ))}
              </select>
            )}
            {selectedModel && (
              <div className="mt-3 text-xs text-muted">
                <div className="mono">{selectedModel.ecr_uri}</div>
                {selectedModel.description && (
                  <div className="mt-1">{selectedModel.description}</div>
                )}
              </div>
            )}
          </div>

          {/* Step 4 — Runtime */}
          <div className="card">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-6 h-6 bg-ink text-paper flex items-center justify-center mono text-xs">4</div>
              <h2 className="mono font-bold">runtime limit</h2>
            </div>
            <div className="flex items-center gap-4">
              <input
                type="range"
                min={1}
                max={selectedModel?.max_runtime_hours || 24}
                value={hours}
                onChange={(e) => setHours(parseInt(e.target.value))}
                className="flex-1"
              />
              <div className="mono font-bold w-16 text-right">{hours}h</div>
            </div>
            <div className="text-xs text-muted mt-2">
              Slurm will kill the job if it exceeds this limit. Max for this model:{" "}
              {selectedModel?.max_runtime_hours || 24}h.
            </div>
          </div>
        </div>

        {/* Right rail — cost summary + submit */}
        <div className="space-y-6">
          <div className="card sticky top-6">
            <h3 className="mono font-bold mb-4 text-sm">summary</h3>
            <dl className="text-sm space-y-2">
              <div className="flex justify-between">
                <dt className="text-muted">input</dt>
                <dd className="mono text-xs text-right max-w-[60%] truncate">
                  {file ? file.name : "—"}
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-muted">gpu</dt>
                <dd className="mono text-xs">
                  {selectedGpu?.display_name || "—"}
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-muted">model</dt>
                <dd className="mono text-xs text-right max-w-[60%] truncate">
                  {selectedModel?.display_name || "—"}
                </dd>
              </div>
              <div className="flex justify-between">
                <dt className="text-muted">runtime</dt>
                <dd className="mono">{hours}h</dd>
              </div>
            </dl>

            <hr className="my-4 border-border" />

            {preview && (
              <div className="space-y-2">
                <div className="flex justify-between text-sm">
                  <span className="text-muted">hourly</span>
                  <span className="mono">${preview.hourly_rate_usd.toFixed(2)}</span>
                </div>
                <div className="flex justify-between">
                  <span className="font-bold">est. cost</span>
                  <span className="mono font-bold text-lg">
                    ${Number(preview.estimated_cost_usd).toFixed(2)}
                  </span>
                </div>
                <div className="flex justify-between text-xs">
                  <span className="text-muted">budget remaining</span>
                  <span className={"mono " + (preview.will_exceed_budget ? "text-red-600" : "")}>
                    ${Number(preview.remaining_budget_usd).toFixed(2)}
                  </span>
                </div>
                {preview.will_exceed_budget && (
                  <div className="text-xs text-red-600 mt-2 p-2 border border-red-200 bg-red-50">
                    This job would exceed your remaining monthly budget. Contact your admin.
                  </div>
                )}
              </div>
            )}

            {submitErr && (
              <div className="text-sm text-red-600 mt-4 mono">{submitErr}</div>
            )}

            <button
              onClick={submit}
              disabled={!canSubmit || submitting}
              className="btn btn-primary w-full mt-6 disabled:opacity-40 disabled:cursor-not-allowed"
            >
              {submitting ? "submitting..." : "submit job"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
