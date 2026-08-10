# ADR 0006 — Public addressing (URL stability)

Status: Accepted · Serves: UC2

## Context
`start` recreates droplets (ADR 0001), so each session gets a **new public IP**
and thus a new UI URL. Question: accept that, or stabilize the address.

## Options
1. **New public IP each start; `start` prints the URL** — zero cost, zero setup;
   URL changes per session.
2. **Reserved IP** — stable IP reassigned to the new droplet each start. Free
   while assigned to an active droplet (small charge if left unassigned); a bit
   more orchestration.
3. **Domain + DNS record** — friendly stable hostname; needs a domain, DNS
   management, and TTL waits on each start.

## Comparison metric
**Setup/cost overhead vs how much URL stability a throwaway demo actually needs.**

## Decision
**Option 1** — new IP each start; the CLI prints the URL and the ready-to-paste
SSH commands.

## Why
A throwaway demo doesn't need a stable URL; printing it each start costs nothing.
Reserved IP (option 2) is noted as an easy future upgrade if a fixed link is ever
wanted — no redesign required.
