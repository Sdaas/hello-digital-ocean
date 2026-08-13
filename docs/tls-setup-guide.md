# TLS setup guide — trusted HTTPS with no owned domain

> How the `digital-ocean` CLI gives a freshly-provisioned droplet **trusted
> HTTPS** — a green padlock, no browser warning — **without buying a domain**,
> using three off-the-shelf pieces: **sslip.io**, **Caddy**, and **Let's
> Encrypt**. Feature F14 ([#31](https://github.com/Sdaas/hello-digital-ocean/issues/31)).

## Why this exists

The app is served on a public droplet. Over plain `http://<ip>:5000` the browser
treats the page as an **insecure context**, so it blocks `getUserMedia()` — the
microphone API. Voice features (e.g. the OPD dictation flow) simply don't work.

The fix is HTTPS with a **trusted** certificate. Normally that means owning a
domain and pointing DNS at the droplet. We want the same result with nothing but
the droplet's IP address. Three tools combine to do exactly that.

## The three pieces

### 1. sslip.io — wildcard DNS that encodes an IP in the hostname

[sslip.io](https://sslip.io) is a public DNS service with one trick: **any**
hostname that contains an IP address resolves back to that IP. Both of these
resolve to `64.227.154.8`:

```
64-227-154-8.sslip.io   →  64.227.154.8   (dashes — what we use)
64.227.154.8.sslip.io   →  64.227.154.8   (dots)
```

We use the **dashed** form so the whole thing is a single DNS label — a valid
certificate name. No account, no DNS records to manage: the droplet's IP *is* the
hostname. (sslip.io is on the Public Suffix List, so each `<ip>.sslip.io` counts
as its own registered domain for rate-limiting — see the caveats below.)

### 2. Let's Encrypt — a free CA that issues trusted certs automatically

[Let's Encrypt](https://letsencrypt.org) is a Certificate Authority trusted by
every mainstream browser. It issues certificates for free through the **ACME**
protocol: a client proves it controls a hostname (the **HTTP-01 challenge** —
serve a token at `http://<host>/.well-known/acme-challenge/...`), and Let's
Encrypt returns a 90-day cert. Because sslip.io makes `<ip>.sslip.io` resolve to
our droplet, and our droplet answers on port 80, the challenge passes.

### 3. Caddy — a web server that does ACME for you

[Caddy](https://caddyserver.com) is a reverse proxy with **automatic HTTPS** built
in. Point it at a hostname and it will, on its own: obtain the Let's Encrypt cert
via ACME, renew it before expiry, redirect `http://`→`https://`, and reverse-proxy
requests to your app. That is the entire config we ship:

```caddy
64-227-154-8.sslip.io {
    reverse_proxy 127.0.0.1:5000
}
```

The app itself binds **loopback only** (`127.0.0.1:5000`); Caddy is the only thing
listening on the public interface (`:443` and `:80`). The plain-http app port is
never exposed.

## How they combine

```
Browser ──https://64-227-154-8.sslip.io──▶ Caddy (:443)  ──http──▶ app (127.0.0.1:5000)
                │                             │
                │  sslip.io resolves the      │  Caddy obtained a trusted cert from
                │  hostname to the droplet IP │  Let's Encrypt over ACME (:80 challenge)
```

1. **sslip.io** turns the droplet's IP into a real hostname — no domain purchase.
2. **Caddy** asks **Let's Encrypt** for a cert for that hostname and passes the
   HTTP-01 challenge (it controls `:80` on the IP the hostname resolves to).
3. Let's Encrypt issues a **browser-trusted** cert; Caddy serves HTTPS with it and
   renews automatically.
4. The browser sees a valid cert → **secure context** → the mic works.

## Worked example (end to end)

Droplet provisioned at **`64.227.154.8`**, app deployed and healthy on
`127.0.0.1:5000`. `digital-ocean start` then runs
[`infra/provision-caddy.sh`](../infra/provision-caddy.sh) over SSH:

1. **Hostname.** `64.227.154.8` → `64-227-154-8.sslip.io`.
2. **Install Caddy** from its official apt repo (idempotent).
3. **Write `/etc/caddy/Caddyfile`:**
   ```caddy
   64-227-154-8.sslip.io {
       reverse_proxy 127.0.0.1:5000
   }
   ```
4. **Start Caddy** (`systemctl restart caddy`). Caddy resolves the hostname to
   itself, requests a cert, Let's Encrypt runs the HTTP-01 challenge on `:80`, and
   issues the cert — usually within seconds.
5. **Verify.** From the droplet:
   ```
   curl -sSI https://64-227-154-8.sslip.io/health   # 200, valid cert
   ```
   In a browser, open `https://64-227-154-8.sslip.io/` — padlock, **no warning**,
   and the mic prompt now appears.

`start` prints the `https://…sslip.io` URL and records it as `APP_URL` in
`.do/state.<env>`. HTTP is redirected to HTTPS automatically.

## Caveats & operations

- **Let's Encrypt rate limits.** Production LE limits certs per registered domain
  per week. Each `<ip>.sslip.io` is its own registered domain, so a single droplet
  is fine — but **repeated `start`/`destroy` cycles on the same IP** can hit the
  limit. While iterating, use the **staging** CA (untrusted cert, very high
  limits):
  ```
  DO_TLS_ACME_STAGING=1 digital-ocean --app-dir . start
  ```
  A staging cert shows a browser warning (expected); switch back to production
  (the default, no flag) for the real deploy.
- **Ports 80 and 443 must be reachable.** ACME's HTTP-01 challenge needs inbound
  `:80`. Firewalls are off by default here; when enabled
  (`DO_ENABLE_FIREWALL=1`), the CLI opens `:443` + `:80` + `:22` (not `:5000`).
- **The internal health probe stays HTTP.** `digital-ocean status` and the
  in-provision health checks hit `http://127.0.0.1:5000/health` on the droplet —
  they check the app, not the TLS edge. The TLS edge is checked separately over
  `https://<host>/health`.
- **This is a stop-gap.** sslip.io + Let's Encrypt is deliberately domain-free for
  demos. A production deployment should use a **real domain** with managed DNS —
  tracked as tech-debt in
  [#32](https://github.com/Sdaas/hello-digital-ocean/issues/32).
