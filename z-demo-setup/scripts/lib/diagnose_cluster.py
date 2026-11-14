#!/usr/bin/env python3
"""Analyse one cluster's pods/events/nodes JSON and print findings.

Usage: diagnose_cluster.py <cluster> <pods.json> <events.json> <nodes.json>

Output, one finding per line, pipe-separated so the shell can tally them:

    SEVERITY|CATEGORY|namespace/pod|message

SEVERITY is ERROR, WARN or INFO. CATEGORY is a fixed tag (IMAGE_SLOW,
IMAGE_PULL, OOM, CRASH, CONFIG, UNSCHEDULABLE, VOLUME, NOT_READY, STUCK,
JOB_FAILED, NODE, EVENT, PULL_STATS) that the summary maps to a likely cause.

Written for the macOS system python3 (3.9): stdlib only, no match/case.
"""
import datetime as dt
import json
import re
import sys

SLOW_PULL_SECONDS = 300      # pulls slower than this are what breaks fixed timeouts
STUCK_SECONDS = 300          # ContainerCreating / not-ready longer than this
NOW = dt.datetime.now(dt.timezone.utc)


def ts(value):
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def event_time(ev):
    for key in ("lastTimestamp", "eventTime", "firstTimestamp"):
        t = ts(ev.get(key))
        if t:
            return t
    return ts(ev.get("metadata", {}).get("creationTimestamp"))


_DUR = re.compile(r"(\d+(?:\.\d+)?)(h|ms|m|s)")


def go_duration(text):
    """'4m16.102s' -> 256.102, '980ms' -> 0.98."""
    total = 0.0
    for num, unit in _DUR.findall(text):
        n = float(num)
        total += {"h": 3600, "m": 60, "s": 1, "ms": 0.001}[unit] * n
    return total


def human(seconds):
    seconds = int(seconds)
    if seconds >= 3600:
        return "%dh%02dm" % (seconds // 3600, seconds % 3600 // 60)
    if seconds >= 60:
        return "%dm%02ds" % (seconds // 60, seconds % 60)
    return "%ds" % seconds


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh).get("items", [])
    except (OSError, ValueError):
        return []


def emit(sev, cat, obj, msg):
    print("%s|%s|%s|%s" % (sev, cat, obj, " ".join(str(msg).split())))


def main():
    _cluster, pods_path, events_path, nodes_path = sys.argv[1:5]
    pods = load(pods_path)
    events = load(events_path)
    nodes = load(nodes_path)

    # ── Image pulls, from kubelet events ────────────────────────────────────
    pulled_re = re.compile(
        r'Successfully pulled image "([^"]+)" in (\S+?)(?: \((\S+) including waiting\))?\.')
    pulls = []                       # (wall_seconds, image, obj)
    pulling = {}                     # (ns/pod, image) -> started
    pulled_keys = set()
    for ev in events:
        io = ev.get("involvedObject", {})
        obj = "%s/%s" % (io.get("namespace", ""), io.get("name", ""))
        msg = ev.get("message", "") or ""
        reason = ev.get("reason", "")
        if reason == "Pulled":
            m = pulled_re.search(msg)
            if m:
                wall = go_duration(m.group(3) or m.group(2))
                pulls.append((wall, m.group(1), obj))
                pulled_keys.add((obj, m.group(1)))
        elif reason == "Pulling":
            m = re.search(r'Pulling image "([^"]+)"', msg)
            if m:
                pulling[(obj, m.group(1))] = event_time(ev)

    for wall, image, obj in sorted(pulls, reverse=True):
        if wall >= SLOW_PULL_SECONDS:
            emit("WARN", "IMAGE_SLOW", obj,
                 "pull took %s (incl. queueing): %s" % (human(wall), image))
    if pulls:
        walls = [p[0] for p in pulls]
        emit("INFO", "PULL_STATS", "-",
             "%d pulls in event window; slowest %s, median %s, %d over %s"
             % (len(walls), human(max(walls)), human(sorted(walls)[len(walls) // 2]),
                sum(1 for w in walls if w >= SLOW_PULL_SECONDS), human(SLOW_PULL_SECONDS)))

    # Pulls that started but have no matching Pulled event yet = in flight now.
    in_flight = {}
    for (obj, image), started in pulling.items():
        if (obj, image) not in pulled_keys and started:
            in_flight[obj] = (image, (NOW - started).total_seconds())

    # ── Mount failures, readiness-probe failures (per pod) ──────────────────
    mount_fail = {}
    unhealthy = {}
    for ev in events:
        if ev.get("type") != "Warning":
            continue
        io = ev.get("involvedObject", {})
        obj = "%s/%s" % (io.get("namespace", ""), io.get("name", ""))
        if ev.get("reason") in ("FailedMount", "FailedAttachVolume"):
            mount_fail[obj] = ev.get("message", "")
        elif ev.get("reason") == "Unhealthy":
            unhealthy[obj] = ev.get("message", "")

    # ── Pods ─────────────────────────────────────────────────────────────────
    for pod in pods:
        meta, st = pod.get("metadata", {}), pod.get("status", {})
        obj = "%s/%s" % (meta.get("namespace", ""), meta.get("name", ""))
        phase = st.get("phase")
        if phase == "Succeeded":
            continue
        age = (NOW - (ts(meta.get("creationTimestamp")) or NOW)).total_seconds()
        conds = dict((c.get("type"), c) for c in st.get("conditions", []))

        if phase == "Failed":
            owner = (meta.get("ownerReferences") or [{}])[0].get("kind", "")
            emit("ERROR", "JOB_FAILED" if owner == "Job" else "CRASH", obj,
                 "pod Failed: %s" % (st.get("reason") or st.get("message") or "see logs"))
            continue

        sched = conds.get("PodScheduled", {})
        if sched.get("status") == "False":
            emit("ERROR", "UNSCHEDULABLE", obj,
                 "%s: %s" % (sched.get("reason", ""), sched.get("message", "")))
            continue

        reported = False
        statuses = (st.get("initContainerStatuses") or []) + (st.get("containerStatuses") or [])
        for cs in statuses:
            name = cs.get("name")
            waiting = cs.get("state", {}).get("waiting") or {}
            reason = waiting.get("reason", "")
            last = (cs.get("lastState") or {}).get("terminated") or {}
            if last.get("reason") == "OOMKilled":
                emit("ERROR", "OOM", obj,
                     "container %s OOMKilled (restarts=%s) - raise its memory limit in "
                     "values-custom.yaml" % (name, cs.get("restartCount")))
                reported = True
            if reason in ("ErrImagePull", "ImagePullBackOff", "InvalidImageName"):
                emit("ERROR", "IMAGE_PULL", obj, "container %s %s: %s"
                     % (name, reason, waiting.get("message", cs.get("image"))))
                reported = True
            elif reason == "CrashLoopBackOff":
                emit("ERROR", "CRASH", obj,
                     "container %s CrashLoopBackOff, last exit %s %s (restarts=%s)"
                     % (name, last.get("exitCode", "?"), last.get("reason", ""),
                        cs.get("restartCount")))
                reported = True
            elif reason in ("CreateContainerConfigError", "CreateContainerError",
                            "RunContainerError"):
                emit("ERROR", "CONFIG", obj, "container %s %s: %s"
                     % (name, reason, waiting.get("message", "")))
                reported = True

        if reported or (phase == "Running" and conds.get("Ready", {}).get("status") == "True"):
            continue

        if obj in in_flight:
            image, secs = in_flight[obj]
            emit("WARN", "IMAGE_SLOW", obj,
                 "still pulling %s for %s" % (image, human(secs)))
        elif obj in mount_fail:
            emit("ERROR", "VOLUME", obj, mount_fail[obj])
        elif phase == "Running":
            if age > STUCK_SECONDS:
                emit("WARN", "NOT_READY", obj, "running but not Ready for %s%s"
                     % (human(age), ("; probe: " + unhealthy[obj]) if obj in unhealthy else ""))
        elif age > STUCK_SECONDS:
            emit("WARN", "STUCK", obj, "phase %s for %s (no pull/mount event explains it)"
                 % (phase, human(age)))

    # ── Nodes ───────────────────────────────────────────────────────────────
    for node in nodes:
        name = node.get("metadata", {}).get("name", "")
        for c in node.get("status", {}).get("conditions", []):
            bad = (c.get("type") == "Ready" and c.get("status") != "True") or \
                  (c.get("type") != "Ready" and c.get("status") == "True")
            if bad:
                emit("ERROR", "NODE", name, "%s=%s: %s"
                     % (c.get("type"), c.get("status"), c.get("message", "")))

    # ── Remaining warning events, deduplicated ──────────────────────────────
    seen = {}
    skip = ("Pulling", "Pulled", "FailedMount", "Unhealthy", "BackOff")
    # Pods referencing a missing (optional) pull secret: harmless for public
    # images but floods the event list, so report it once as a count.
    no_pull_secret = set()
    for ev in events:
        if ev.get("reason") == "FailedToRetrieveImagePullSecret":
            no_pull_secret.add(ev.get("involvedObject", {}).get("namespace", ""))
            continue
        if ev.get("type") != "Warning" or ev.get("reason") in skip:
            continue
        io = ev.get("involvedObject", {})
        key = (ev.get("reason"), io.get("kind"), io.get("namespace"), io.get("name"))
        seen[key] = (seen.get(key, (0, ""))[0] + (ev.get("count") or 1), ev.get("message", ""))
    if no_pull_secret:
        emit("INFO", "EVENT", "-", "pods in %d namespaces reference a missing image-pull-secret "
             "(harmless for public images): %s" % (len(no_pull_secret),
                                                  ", ".join(sorted(no_pull_secret))[:200]))
    for (reason, kind, ns, name), (count, msg) in sorted(
            seen.items(), key=lambda kv: -kv[1][0])[:15]:
        emit("INFO", "EVENT", "%s/%s %s" % (ns or "-", name, kind),
             "%s x%d: %s" % (reason, count, msg[:200]))


if __name__ == "__main__":
    main()
