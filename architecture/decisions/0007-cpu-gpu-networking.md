# ADR 0007 — CPU↔GPU networking

Status: Accepted · Serves: UC2, UC5

## Context
The Flask backend (CPU droplet) calls Ollama (GPU droplet, :11434) on every chat
turn. Both droplets are co-located in one region (default AMS3). "No security"
overall, but Ollama has no auth, so exposing :11434 publicly = open model server.

## Options
1. **Public IPs only** — backend hits GPU's public IP:11434. Simplest, but
   Ollama is world-reachable and every chat turn crosses the public network.
2. **Private VPC network** — both droplets on a DO VPC; backend hits GPU's
   private IP:11434; Ollama not exposed publicly. Same-region, low latency,
   effectively free.

## Comparison metric
**Ollama exposure + CPU↔GPU latency, at equal cost.**

## Decision
**Option 2** — put both droplets on a private VPC; backend → Ollama over the
private IP; only the backend's :5000 is public.

## Why
Co-location already makes a VPC free and low-latency, and it keeps the
unauthenticated Ollama port off the public internet — a meaningful reduction in
exposure for zero cost, without contradicting the "no app-level security" stance.

## Amendment (2026-08-11, #19) — private-IP binding is the primary control
The merged F7 `start` kept Ollama bound to `0.0.0.0:11434` and relied on a **DO
cloud firewall** to keep :11434 off the public net. That put firewall creation on
`start`'s critical path and required a firewall-scoped token (#16).

The VPC decision above does not actually need a firewall. **Ollama now binds the
node's private VPC IP** (`OLLAMA_HOST=<private_ip>:11434`), so it is simply not
listening on the public interface — ADR-0007's intent is satisfied with **no
firewall, on the current token**. The DO firewall becomes **optional
defense-in-depth**, gated behind `DO_ENABLE_FIREWALL` (default off); when enabled
it applies the same VPC-scoped :11434 rule as before. Private-IP binding is the
control of record; the firewall is a belt-and-suspenders extra.

This also applies unchanged when the Ollama node is a **CPU** droplet
(`OLLAMA_BACKEND=cpu`, #18) rather than a GPU droplet — the isolation mechanism is
the private-IP bind, independent of backend.
