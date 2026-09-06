# The workload that stands in for otel-service-reference when it is not on disk.
#
# A reference platform whose `make up` needs a second private repository is a
# reference platform nobody but its author can run, so the bring-up has to work
# without it. What it must NOT do is pretend: the previous fallback pulled
# nginx-unprivileged and tagged it, on the claim that it satisfied every
# guardrail including "probeable". It did not. The chart probes /healthz on
# 8080 and stock nginx serves no such path, so the startup probe killed the
# container every 30s and the Application sat Degraded until its 900s deadline
# -- a failure that had nothing to do with the platform and everything to do
# with the placeholder.
#
# One config file is the difference between a placeholder that demonstrates the
# paved road and one that cannot get past its own readiness gate.
#
# The base is passed in rather than written here so that versions.env stays the
# single source of truth for the pin; scripts/sample-image.sh supplies it from
# SAMPLE_IMAGE_FALLBACK.
ARG BASE
FROM ${BASE}

# Replaces the image's own default.conf, which listens on 8080 and serves the
# nginx welcome page and nothing else.
COPY quote-api.conf /etc/nginx/conf.d/default.conf

# Declared for the reader; the chart is what actually publishes them. The base
# image already runs as UID 101, and nothing here changes that -- the
# require-probes-and-nonroot guardrail rejects the pod otherwise.
EXPOSE 8080 8081
