# Task 03 — Incident Scenarios

## Question 1 — Service returning 503

**My choice:** D

**Reasoning:** A 503 often means the service is reachable but cannot complete the request because an upstream dependency is failing or unavailable. I would first verify databases, caches, upstream APIs, or load-balancer backends to quickly determine whether the issue is local or dependency-driven.

**Why not the others first:** Logs, recent changes, and host resources are still useful next checks, but starting with dependencies is faster when the symptom is a server-side availability failure that may be caused outside the service itself.

## Question 2 — Alert storm after a config change

**My choice:** A

**Reasoning:** If a config change immediately triggers hundreds of alerts, rollback is the fastest way to return to the last known good state and reduce blast radius. After service health is restored, I would investigate the exact bad setting or shared dependency.

**Why not the others first:** Identifying common dependencies, triaging by severity, and checking monitoring are all reasonable, but they take time while production may still be degraded. Since the config change is the clear trigger, rollback should come before deeper analysis.

## Question 3 — Latency spike, no alert fired

**My choice:** A

**Reasoning:** My immediate concern is that latency alerting is missing, too loose, or not aligned with the user-facing SLO. If users notice a jump from 200 ms to 2 seconds before alerts fire, the monitoring strategy is not protecting the user experience.

**Why not the others first:** Coarse metrics, availability-only SLOs, and gradual degradation can all explain the miss, but they are more specific root causes. The first concern is the broader alerting gap: the system failed to detect a clear user-facing latency regression.
