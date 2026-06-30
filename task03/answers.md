# Task 03 — Incident Scenarios

## Question 1 — Service returning 503

**Your choice:** D

**Reasoning:** A 503 usually means the service cannot serve requests because one of its dependencies is unhealthy. I would check upstreams, databases, caches, or other backend dependencies first to quickly determine whether the failure is local to the service or coming from somewhere else.

## Question 2 — Alert storm after a config change

**Your choice:** A

**Reasoning:** If a config change immediately triggers alerts across many services, rollback is the fastest way to restore the last known good state and reduce blast radius. I would investigate the shared dependency or bad config only after the system is stable again.

## Question 3 — Latency spike, no alert fired

**Your choice:** A

**Reasoning:** My immediate concern is that latency alerting is missing, too loose, or not aligned with the user-facing SLO. If users feel the slowdown before alerts fire, the monitoring strategy needs fixing so we do not stay blind to performance regressions.
