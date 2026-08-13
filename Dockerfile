FROM pytorch/pytorch:2.5.1-cuda12.4-cudnn9-devel

LABEL org.opencontainers.image.source="https://github.com/MagdalenaZZ/Dance_now" \
      org.opencontainers.image.description="Wan 2.2 TI2V-5B image-to-video worker for AWS Batch. Built and published from that source via AWS CodeBuild — nothing added or changed by hand." \
      org.opencontainers.image.licenses="MIT"

ARG WAN_REF=main
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/models/huggingface

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg git \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 --branch "${WAN_REF}" https://github.com/Wan-Video/Wan2.2.git /opt/Wan2.2 \
    && pip install -r /opt/Wan2.2/requirements.txt \
    && pip install "boto3>=1.34,<2" "huggingface_hub>=0.27,<2"

COPY pyproject.toml /app/pyproject.toml
COPY src /app/src
COPY worker/worker.py /app/worker.py
RUN pip install --no-deps /app

ENV PYTHONPATH=/opt/Wan2.2:/app/src
WORKDIR /app
ENTRYPOINT ["python", "/app/worker.py"]

