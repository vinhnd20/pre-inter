# Task 02 — Centralized Log Management Design

This folder contains the architecture diagram for a centralized log management
system sized for roughly **1,000–2,000 endpoints**.

## Deliverable

- [PNG architecture diagram](images/log-management-architecture.png)

## What the design shows

### Collection and transport

- Kubernetes workloads send logs through a node-level Vector DaemonSet.
- VM and bare-metal servers send logs through a local Vector agent.
- Logs flow from agents to a central Vector aggregation layer.
- The aggregation layer forwards streams into Kafka for durable buffering and
  decoupling.
- A downstream Vector consumer reads from Kafka and delivers normalized logs to
  Loki for search and alerting.
- Grafana reads from Loki and handles visualization and alerting workflows.
- Object storage is used for archival offload.

### Parsing, normalization, enrichment

- Parsing happens close to the source in Vector so logs are structured early.
- Normalization and enrichment also happen in Vector aggregation:
  - parse application, system, and platform-specific formats
  - enrich with host, environment, cluster, and service metadata
  - mask or drop sensitive fields before storage

### Storage, retention, archival

- Loki is the hot searchable store for recent logs and operational queries.
- Kafka provides short-term resilience and backpressure handling, not long-term
  retention.
- Retention can be designed in one of two ways:
  - **Hot-search model**: keep logs in Loki for **90 days** when operators need
    frequent access to historical data and can accept higher storage cost.
  - **Archive model**: keep Loki retention shorter, then send a copy of raw logs
    to a separate S3 archive bucket for compliance and long-term audit needs.
- In practice, the archive model is usually better for compliance because it
  keeps Loki fast while preserving a second, cheaper retention tier.
- If a separate archive tier is used, the hot tier and archive tier should have
  different retention policies:
  - hot search in Loki for **90 days**
  - archive bucket for **365 days**
  - delete according to compliance and cost needs

## Why this design fits the size

- Vector is lightweight enough for 1,000–2,000 endpoints.
- Kafka absorbs spikes and protects downstream storage from overload.
- Loki keeps search simple for operators while object storage keeps costs down.
- The split between edge collection and central aggregation avoids direct fan-in
  from every source to storage.
- The architecture scales because the hot path and archive path can be tuned
  independently.

## Concrete retention policy

For this design, the recommended defaults are:

- Kafka retention: **24 hours to 7 days**
- Loki retention: **90 days**
- S3 archive bucket retention: **365 days**

This keeps the hot path fast while preserving a full year of raw logs for audit
and compliance review.

## Notes

- The diagram is intentionally technology-specific but the pattern is portable.
- For network devices, syslog or vendor exporters can feed the same Vector
  ingestion tier.
- For production use, add TLS, auth, and queue sizing based on measured ingest
  rate.
