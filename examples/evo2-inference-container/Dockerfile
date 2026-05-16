# Example thin-container pattern for titan-hpc.
#
# Key properties:
#  - Base on CUDA runtime (not devel — smaller image)
#  - Weights are NOT baked in; they're read from /models at runtime
#  - Code accepts --weights, --input, --output matching the jobui schema
#  - Image stays under 5 GB

FROM nvidia/cuda:12.2.0-runtime-ubuntu22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
      python3 \
      python3-pip \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install only the inference libs you need — keep this list minimal
RUN pip3 install --no-cache-dir \
      torch==2.4.1 \
      transformers==4.44.2 \
      accelerate==0.34.2 \
      numpy==1.26.4

WORKDIR /opt/inference
COPY inference.py /opt/inference/inference.py

# Entrypoint — the job script appends --weights, --input, --output
ENTRYPOINT ["python3", "/opt/inference/inference.py"]
