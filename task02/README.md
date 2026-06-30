# Task 02 — Centralized Log Management Design

This folder contains the architecture diagram for a centralized log management
system sized for roughly **1,000–2,000 endpoints**.

## Deliverable

- [PNG architecture diagram](images/log-management-architecture.png)

## What the design shows

The three source classes the assignment calls out — **servers, network
devices, and applications** — each have a distinct collection path because they
cannot all run an agent:

| Source class | How logs are collected | Transport into the pipeline |
|--------------|------------------------|-----------------------------|
| **Kubernetes / containerized apps** | Node-level Vector **DaemonSet** tails container stdout/stderr and reads pod metadata | → Vector aggregation |
| **VM / bare-metal servers** | Local **Vector agent** (or `journald`/file source) | → Vector aggregation |
| **Network devices** (switches, routers, firewalls) | **Cannot run an agent** — they emit **syslog (UDP/TCP 514)**, and metrics via SNMP. A dedicated Vector **`syslog` source** acts as the collector | → Vector aggregation |
| **Applications** | Structured logs (JSON) via stdout, file, or direct HTTP/`vector` sink | → Vector aggregation |

From there the flow is uniform:

- Agents and the syslog collector forward to a **central Vector aggregation
  layer** (run as ≥2 instances behind a load balancer — see *Availability*).
- The aggregation layer forwards streams into **Kafka** for durable buffering
  and decoupling (producers and consumers fail independently).
- A downstream **Vector consumer** reads from Kafka and delivers normalized logs
  to **Loki** for search and alerting.
- **Grafana** reads from Loki and handles visualization and alerting workflows.
- **Object storage (S3)** is used for archival offload.

Network devices are treated as a first-class source, not an afterthought: a
dedicated syslog ingestion tier means a misbehaving device (e.g. a firewall
log storm) is buffered by Kafka instead of overwhelming storage.

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

## Technology choices and tradeoffs

The stack is a deliberate set of tradeoffs, not a default:

- **Vector** (collection/aggregation) over Fluentd/Logstash: lower memory
  footprint per agent, a single binary for both edge and aggregation roles, and
  built-in transforms (parse/enrich/redact) so we don't need a separate
  processing tier.
- **Kafka** as the buffer over a direct agent→storage path: it decouples
  producers from consumers, absorbs spikes, and becomes the durability boundary
  that lets storage be restarted or replaced without losing logs.
- **Loki** over Elasticsearch/OpenSearch: Loki indexes only labels (not full
  text), so it is **much cheaper to run and operate** at this scale and pairs
  naturally with cheap object storage. The accepted tradeoff is **weaker
  full-text search and a sensitivity to high label cardinality** — for an
  operational/troubleshooting workload (filter by service/host/level, then grep
  within a stream) this is the right balance. If the requirement were heavy
  ad-hoc full-text analytics or security/SIEM-grade search, OpenSearch would be
  the better fit and the design would swap the storage tier while keeping the
  Vector→Kafka front end unchanged.

## Why this design fits the size

- Vector is lightweight enough for 1,000–2,000 endpoints.
- Kafka absorbs spikes and protects downstream storage from overload.
- Loki keeps search simple for operators while object storage keeps costs down.
- The split between edge collection and central aggregation avoids direct fan-in
  from every source to storage.
- The architecture scales because the hot path and archive path can be tuned
  independently.

## Capacity assumptions (ballpark)

Sizing should be confirmed against measured ingest, but the design is anchored
to a working estimate so the component counts are defensible:

- **1,000–2,000 endpoints**, assume an average of ~5 GB/day each at the high end
  → **~5–10 TB/day** raw, on the order of **100k–200k events/sec** at peak.
- **Kafka**: 3-broker cluster, replication factor 3, topic partitioned (e.g. 12+
  partitions) so the Vector consumers can scale horizontally. 1–7 day retention
  is the buffer, not the system of record.
- **Loki**: run distributed (separate ingester/querier/distributor) rather than
  single-binary at this scale; object storage (S3) as the chunk backend.
- **Vector aggregation**: start with 2–3 instances, scale on CPU/throughput.

These are starting points; the real numbers come from a short measurement
period before go-live.

## Availability

No tier is a single point of failure:

- **Vector aggregation** runs as **≥2 instances behind a load balancer**. Agents
  and the syslog collector point at the LB endpoint, so losing one instance does
  not drop ingestion.
- **Kafka** is a 3-broker cluster with replication factor 3 — it tolerates a
  broker loss and is the durability boundary: if Loki is down, logs accumulate
  in Kafka and are replayed when it recovers (no data loss within retention).
- **Loki** runs distributed with replicated ingesters; S3 provides durable
  chunk/long-term storage.
- **Agents** buffer to local disk when the aggregation layer is briefly
  unreachable, so short outages do not lose logs at the edge.

## Concrete retention policy

For this design, the recommended defaults are:

- Kafka retention: **24 hours to 7 days**
- Loki retention: **90 days**
- S3 archive bucket retention: **365 days**

This keeps the hot path fast while preserving a full year of raw logs for audit
and compliance review.

## Security and operational notes

- **In transit**: TLS on every hop — agents→aggregation, aggregation→Kafka
  (SASL/TLS), Kafka→Loki, and Grafana access behind SSO. Network-device syslog
  is plaintext by default, so terminate it on a hardened collector inside the
  management network rather than exposing 514 broadly.
- **At rest**: encrypt the S3 archive bucket; apply a bucket lifecycle policy
  matching the retention table; restrict access via IAM.
- **PII**: redaction/drop happens in Vector aggregation *before* Kafka and
  storage, so sensitive fields never land in the durable tiers.
- The diagram is intentionally technology-specific, but the pattern
  (edge collect → buffer → normalize → hot store + archive) is portable to other
  stacks (Fluent Bit / Kafka / OpenSearch, etc.).
