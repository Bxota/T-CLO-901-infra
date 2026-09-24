#!/usr/bin/env python3
"""Render pinned charts and check effective memory budgets (requires Helm/PyYAML).

Optional CHART_CACHE contains <chart>-<version>.tgz; otherwise Helm uses repoURL.
This deliberately checks rendered containers: Helm silently ignores unknown keys.
"""
import os
from pathlib import Path
import subprocess
import tempfile

import yaml

ROOT = Path(__file__).resolve().parents[1]
APPS = [
    "platform/identity/keycloak/00-keycloak.application.yaml",
    "platform/observability/20-kube-prometheus-stack.application.yaml",
    "platform/observability/30-loki.application.yaml",
    "platform/observability/40-alloy.application.yaml",
]
TARGETS = {"keycloak", "grafana", "grafana-sc-dashboard", "grafana-sc-datasources",
           "loki", "loki-sc-rules", "alloy", "config-reloader"}


def mib(value):
    value = str(value)
    for suffix, factor in (("Gi", 1024), ("Mi", 1), ("Ki", 1 / 1024)):
        if value.endswith(suffix):
            return float(value[:-len(suffix)]) * factor
    return float(value) / 1048576


def budget(resources, name):
    request = mib(resources.get("requests", {}).get("memory", 0))
    limit = mib(resources.get("limits", {}).get("memory", 0))
    assert 0 < request <= limit, f"{name}: missing/invalid memory request or limit: {resources}"


def main():
    seen = set()
    failures = []
    with tempfile.TemporaryDirectory() as tmp:
        for relative in APPS:
            app = yaml.safe_load((ROOT / relative).read_text())
            source = app["spec"]["source"]
            values = Path(tmp) / "values.yaml"
            values.write_text(source["helm"]["values"])
            chart = Path(os.environ.get("CHART_CACHE", tmp)) / f'{source["chart"]}-{source["targetRevision"]}.tgz'
            args = [str(chart)] if chart.exists() else [source["chart"], "--repo", source["repoURL"], "--version", source["targetRevision"]]
            output = subprocess.check_output([
                "helm", "template", source["helm"]["releaseName"], *args,
                "--namespace", app["spec"]["destination"]["namespace"],
                "--kube-version", "1.36.0", "-f", str(values),
            ], text=True)
            for obj in yaml.safe_load_all(output):
                if not obj:
                    continue
                kind, spec = obj["kind"], obj.get("spec", {})
                if kind in ("Deployment", "StatefulSet", "DaemonSet"):
                    pod = spec["template"]["spec"]
                    if any(c["name"] == "keycloak" for c in pod["containers"]):
                        assert spec.get("updateStrategy", {}).get("type") == "OnDelete", "Do not recreate the ephemeral Keycloak database automatically (see docs/runbooks/worker-memory.md)"
                    for container in pod["containers"]:
                        name = container["name"]
                        if name in TARGETS:
                            seen.add(name)
                            try:
                                budget(container.get("resources", {}), name)
                            except AssertionError as exc:
                                failures.append(str(exc))
                    if any(c["name"] == "grafana" for c in pod["containers"]):
                        terms = pod.get("affinity", {}).get("podAntiAffinity", {}).get("preferredDuringSchedulingIgnoredDuringExecution", [])
                        assert any(t["podAffinityTerm"].get("namespaces") == ["identity"]
                                   and t["podAffinityTerm"]["topologyKey"] == "kubernetes.io/hostname"
                                   and t["podAffinityTerm"]["labelSelector"].get("matchLabels", {}).get("app.kubernetes.io/instance") == "keycloak"
                                   for t in terms), "Grafana must prefer a different worker from Keycloak"
                elif kind in ("Prometheus", "Alertmanager"):
                    try:
                        budget(spec.get("resources", {}), kind)
                    except AssertionError as exc:
                        failures.append(str(exc))
            print(f"Rendered {source['chart']} {source['targetRevision']}")
    assert seen >= TARGETS, f"Expected containers absent: {TARGETS - seen}"
    assert not failures, "\n".join(failures)
    controller = yaml.safe_load((ROOT / "playbooks/files/argocd-controller-resources.yaml").read_text())
    container = controller["spec"]["template"]["spec"]["containers"][0]
    assert container["name"] == "argocd-application-controller"
    budget(container["resources"], container["name"])
    print("Effective memory requests/limits and Grafana placement: OK")


if __name__ == "__main__":
    main()
