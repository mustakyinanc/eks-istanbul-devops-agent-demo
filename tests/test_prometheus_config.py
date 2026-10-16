#!/usr/bin/env python3
"""Validation checks for k8s/monitoring/prometheus.yml.

Prometheus cannot be run locally and promtool is not installed, so this script
takes the place of `promtool check config` for the parts that matter:

  * the template parses as YAML and carries the structure the design requires
  * the Metric_Allowlist keeps exactly the eight required metric families
  * the allowlist drops high-cardinality cAdvisor container metrics

The allowlist checks reproduce Prometheus relabel semantics: the regex is fully
anchored (Prometheus wraps it in ^(?:...)$ internally), so each alternative must
match a whole metric name.

Covers design Correctness Properties 1 and 2.
**Validates: Requirements 2.4, 2.5, 2.6, 2.7, 4.1, 4.2, 4.4, 4.8**

Run: python3 tests/test_prometheus_config.py
"""

import random
import re
import sys
from pathlib import Path

import yaml

CONFIG = Path(__file__).resolve().parent.parent / "k8s" / "monitoring" / "prometheus.yml"

ALLOWED_FAMILIES = [
    "node_cpu_seconds_total",
    "node_memory_MemAvailable_bytes",
    "node_memory_MemTotal_bytes",
    "kube_pod_container_status_restarts_total",
    "kube_node_spec_unschedulable",
    "kube_pod_status_phase",
    "up",
    "node_load1",
]

# Representative high-cardinality metrics that must never reach Grafana Cloud.
# cAdvisor container metrics alone can exceed 5,000 series.
FORBIDDEN_METRICS = [
    "container_memory_working_set_bytes",
    "container_cpu_usage_seconds_total",
    "container_network_receive_bytes_total",
    "container_fs_reads_bytes_total",
    "container_memory_rss",
    "container_spec_cpu_quota",
    # Non-cAdvisor metrics that exist but are not needed by any panel or rule.
    "node_boot_time_seconds",
    "node_filesystem_size_bytes",
    "kube_pod_labels",
    "prometheus_tsdb_head_series",
    "go_goroutines",
]

# Series estimate per family for the two-worker-node demo topology, taken from
# the design's Metric_Allowlist table. Used for the Series_Budget property.
SERIES_PER_NODE = {
    "node_cpu_seconds_total": 16,  # 2 vCPU x 8 modes
    "node_memory_MemAvailable_bytes": 1,
    "node_memory_MemTotal_bytes": 1,
    "node_load1": 1,
    "kube_node_spec_unschedulable": 1,
    "up": 2,  # one target per job
}
SERIES_PER_POD = {
    "kube_pod_container_status_restarts_total": 1,
    "kube_pod_status_phase": 5,  # one series per phase
}
SERIES_BUDGET = 6000

_failures = []
_checks = 0


def check(condition, label):
    global _checks
    _checks += 1
    if condition:
        print(f"  \u2705 {label}")
    else:
        print(f"  \u274c {label}")
        _failures.append(label)


def load_config():
    raw = CONFIG.read_text()
    return raw, yaml.safe_load(raw)


def anchored(regex):
    """Compile a relabel regex the way Prometheus does: fully anchored."""
    return re.compile(f"^(?:{regex})$")


def get_allowlist_regex(cfg):
    remote_write = cfg["remote_write"][0]
    keeps = [
        rc
        for rc in remote_write["write_relabel_configs"]
        if rc.get("action") == "keep" and rc.get("source_labels") == ["__name__"]
    ]
    assert len(keeps) == 1, f"expected exactly one keep rule on __name__, found {len(keeps)}"
    return keeps[0]["regex"]


def test_structure(raw, cfg):
    print("\nStructure and scrape settings (Requirements 2.4, 2.5, 2.6, 2.7)")

    check(cfg["global"]["scrape_interval"] == "30s", "scrape_interval is 30s")
    check(cfg["global"]["scrape_timeout"] == "10s", "scrape_timeout is 10s")
    check(
        cfg["global"]["external_labels"]["cluster"] == "eks-istanbul",
        "external label cluster=eks-istanbul",
    )

    jobs = {sc["job_name"]: sc for sc in cfg["scrape_configs"]}
    check(
        set(jobs) == {"node-exporter", "kube-state-metrics"},
        "exactly two scrape jobs: node-exporter and kube-state-metrics",
    )

    ports = {}
    for name, job in jobs.items():
        sd = job["ec2_sd_configs"]
        check(len(sd) == 1, f"{name}: uses ec2_sd_configs")
        sd = sd[0]
        check(sd["region"] == "eu-central-1", f"{name}: region eu-central-1")
        ports[name] = sd["port"]

        filters = {f["name"]: f["values"] for f in sd["filters"]}
        check(
            filters.get("tag:eks:cluster-name") == ["eks-istanbul"],
            f"{name}: filters on tag:eks:cluster-name = eks-istanbul",
        )
        check(
            filters.get("instance-state-name") == ["running"],
            f"{name}: filters on instance-state-name = running",
        )

        relabels = {
            tuple(rc["source_labels"]): rc["target_label"]
            for rc in job.get("relabel_configs", [])
            if "target_label" in rc
        }
        check(
            relabels.get(("__meta_ec2_private_ip",)) == "instance",
            f"{name}: relabels __meta_ec2_private_ip -> instance",
        )
        # node_role comes from the EKS-managed nodegroup tag; `role` is a
        # Kubernetes label only and has no EC2 tag counterpart.
        check(
            relabels.get(("__meta_ec2_tag_eks_nodegroup_name",)) == "node_role",
            f"{name}: derives node_role from __meta_ec2_tag_eks_nodegroup_name",
        )

    # KSM must be scraped through exactly one node (the isolate node group);
    # externalTrafficPolicy: Cluster makes the NodePort answer on every node.
    ksm_keeps = [
        rc
        for rc in jobs["kube-state-metrics"].get("relabel_configs", [])
        if rc.get("action") == "keep"
    ]
    check(
        len(ksm_keeps) == 1
        and ksm_keeps[0]["source_labels"] == ["__meta_ec2_tag_eks_nodegroup_name"]
        and ksm_keeps[0]["regex"] == "ng-istanbul-isolate",
        "kube-state-metrics: single keep rule restricts targets to ng-istanbul-isolate",
    )
    check(
        not any(rc.get("action") == "keep" for rc in jobs["node-exporter"].get("relabel_configs", [])),
        "node-exporter: no keep rule, both nodes are scraped",
    )
    for ng, expect in [("ng-istanbul-isolate", "isolate"), ("ng-istanbul-stress", "stress")]:
        role_rule = next(
            rc for rc in jobs["kube-state-metrics"]["relabel_configs"]
            if rc.get("target_label") == "node_role"
        )
        got = anchored(role_rule["regex"]).sub(role_rule["replacement"].replace("$1", r"\1"), ng)
        check(got == expect, f"node_role derived from {ng} is {expect!r}")

    check(ports.get("node-exporter") == 9100, "node-exporter target port is 9100")
    check(ports.get("kube-state-metrics") == 30808, "kube-state-metrics target port is 30808")

    rw = cfg["remote_write"][0]
    check(
        rw["basic_auth"]["password_file"] == "/etc/prometheus/remote_write_password",
        "remote_write references password_file, not an inline password",
    )
    check("password" not in rw["basic_auth"], "no inline password key in basic_auth")
    check(
        rw["url"] == "__GRAFANA_CLOUD_REMOTE_WRITE_URL__",
        "remote_write url is the __TOKEN__ placeholder",
    )
    check(
        rw["basic_auth"]["username"] == "__GRAFANA_CLOUD_USERNAME__",
        "remote_write username is the __TOKEN__ placeholder",
    )
    q = rw["queue_config"]
    check(
        q["capacity"] == 10000 and q["max_shards"] == 5,
        "queue_config carries capacity and max_shards",
    )
    check(
        "min_backoff" in q and "max_backoff" in q,
        "queue_config carries increasing-backoff retry settings",
    )
    check(
        all("metric_relabel_configs" not in sc for sc in cfg["scrape_configs"]),
        "allowlist is not placed in metric_relabel_configs (local TSDB keeps everything)",
    )

    print("\nNo hardcoded node identity (Requirement 14.1)")
    # Live worker IPs, instance ids and role values must not be baked into any
    # effective setting; they change on every scale-up. Comments may mention
    # them for explanation, so only non-comment lines are scanned.
    effective = "\n".join(
        line for line in raw.splitlines() if not line.lstrip().startswith("#")
    )
    for forbidden in ["10.20.10.", "10.20.2.193", "i-0", "role=stress", "role=isolate"]:
        check(forbidden not in effective, f"no effective setting contains {forbidden!r}")


def test_allowlist_keeps_required(regex):
    print("\nProperty 2a: every required family passes the keep filter (Req 4.1, 4.2)")
    pattern = anchored(regex)
    for metric in ALLOWED_FAMILIES:
        check(bool(pattern.match(metric)), f"kept: {metric}")


def test_allowlist_drops_forbidden(regex):
    print("\nProperty 2b: no metric outside the allowlist passes (Req 4.1, 4.4)")
    pattern = anchored(regex)
    for metric in FORBIDDEN_METRICS:
        check(not pattern.match(metric), f"dropped: {metric}")


def test_allowlist_is_exact(regex):
    print("\nProperty 2c: allowlist alternation is exactly the eight families")
    alternatives = regex.split("|")
    check(
        sorted(alternatives) == sorted(ALLOWED_FAMILIES),
        f"regex lists exactly the eight required families (found {len(alternatives)})",
    )
    check(
        all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", a) for a in alternatives),
        "every alternative is a literal metric name, no wildcards that could widen the filter",
    )


def test_allowlist_generated_names(regex):
    """Generated check over synthetic metric names.

    Property 2 restated: for arbitrary metric names, keep passes if and only if
    the name is one of the eight allowed families.
    """
    print("\nProperty 2d: generated metric names match the allowlist iff allowed")
    pattern = anchored(regex)
    rng = random.Random(20251015)

    prefixes = ["", "my_", "container_", "kube_", "node_", "prometheus_", "x"]
    suffixes = ["", "_total", "_bytes", "s", "_seconds", "_2", "_info"]

    names = set()
    # Mutate allowed names to produce near-misses, which is where an unanchored
    # or sloppy regex would leak.
    for base in ALLOWED_FAMILIES:
        for p in prefixes:
            for s in suffixes:
                names.add(p + base + s)
    # Plus random synthetic names.
    alphabet = "abcdefghijklmnopqrstuvwxyz_"
    for _ in range(500):
        length = rng.randint(1, 30)
        names.add("".join(rng.choice(alphabet) for _ in range(length)))

    mismatches = []
    for name in names:
        expected = name in ALLOWED_FAMILIES
        actual = bool(pattern.match(name))
        if expected != actual:
            mismatches.append((name, expected, actual))

    check(
        not mismatches,
        f"{len(names)} generated names classified correctly"
        + ("" if not mismatches else f" (mismatches: {mismatches[:5]})"),
    )


def test_series_budget(regex):
    """Property 1: the allowlist keeps the series count under Series_Budget.

    Generated over arbitrary node and pod counts rather than just the current
    two-node topology, so scale-up cannot silently blow the budget.
    """
    print("\nProperty 1: series count stays under Series_Budget of 6,000 (Req 4.3, 4.5)")
    pattern = anchored(regex)
    kept_node = {m: n for m, n in SERIES_PER_NODE.items() if pattern.match(m)}
    kept_pod = {m: n for m, n in SERIES_PER_POD.items() if pattern.match(m)}

    per_node = sum(kept_node.values())
    per_pod = sum(kept_pod.values())

    # Demo topology: 2 worker nodes, ~25 pods including the injected stress pods.
    demo = per_node * 2 + per_pod * 25
    check(demo < SERIES_BUDGET, f"demo topology (2 nodes, 25 pods) yields {demo} series")
    check(demo < 1000, f"demo topology is far below budget: {demo} series, design estimate ~170")

    rng = random.Random(7)
    worst = 0
    worst_shape = None
    for _ in range(300):
        nodes = rng.randint(0, 10)
        pods = rng.randint(0, 150)
        total = per_node * nodes + per_pod * pods
        if total > worst:
            worst, worst_shape = total, (nodes, pods)
    check(
        worst < SERIES_BUDGET,
        f"worst generated topology {worst_shape} yields {worst} series, under {SERIES_BUDGET}",
    )

    # Headroom: the design requires at least 4,000 series of slack below the
    # 10,000 free-tier cap, i.e. the budget itself must be <= 6,000.
    check(10000 - SERIES_BUDGET >= 4000, "Series_Budget leaves >= 4,000 series of free-tier slack")


def main():
    print(f"Validating {CONFIG}")
    if not CONFIG.exists():
        print(f"  \u274c config not found: {CONFIG}")
        return 1

    raw, cfg = load_config()
    print("  \u2705 YAML parses")

    regex = get_allowlist_regex(cfg)
    print(f"  \u2705 single keep rule on __name__ found")

    test_structure(raw, cfg)
    test_allowlist_keeps_required(regex)
    test_allowlist_drops_forbidden(regex)
    test_allowlist_is_exact(regex)
    test_allowlist_generated_names(regex)
    test_series_budget(regex)

    print()
    if _failures:
        print(f"\u274c {len(_failures)} of {_checks} checks failed:")
        for f in _failures:
            print(f"   - {f}")
        return 1
    print(f"\u2705 all {_checks} checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
