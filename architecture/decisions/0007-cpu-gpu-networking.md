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
