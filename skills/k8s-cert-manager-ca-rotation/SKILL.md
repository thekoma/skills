---
name: k8s-cert-manager-ca-rotation
description: "Use when a cert-manager CA rotates and TLS breaks."
version: 1.0.0
author: curator
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [kubernetes, cert-manager, tls, ca, trust-manager, reloader, pki]
---

# cert-manager CA Rotation & Cascading Trust Breaks

Class of task: a `ClusterIssuer`/`Issuer` of type `ca:` rotated its signing CA (the `Certificate` backing it renewed), and now some consumer breaks with `x509: certificate signed by unknown authority`, an ArgoCD sync failure through an admission webhook, or a pod that silently kept an old cert. This is a structural gap in cert-manager, not a misconfiguration to hunt for in your own manifests first.

## The core fact (verify, don't assume)

**cert-manager does not cascade-reissue leaf certificates when their issuing CA rotates.** This is a known, still-open upstream gap:
- https://github.com/cert-manager/cert-manager/issues/2478 (open since 2019)
- https://github.com/cert-manager/cert-manager/issues/9076 (SKI/AKI mismatch on CA renew, same symptom)
- Docs say it plainly: "Updating the secret used for the CA certificate won't trigger re-issuance of leaf certificates... cmctl renew may be helpful for this."

So: CA secret changes → existing `Certificate` leaves keep their old signature until they hit their **own** natural renewal window. If the CA rotates faster than that window, you get a live leaf signed by a CA that's no longer trusted anywhere (trust-manager's `Bundle`/`default-bundle` only carries the *current* CA, not history).

**Reloader (stakater) does not close this gap either.** Reloader watches Secret/ConfigMap *content* changes and restarts pods that reference them — it has nothing to do with cert-manager's issuance decision. If the leaf Secret's bytes never changed (because cert-manager never reissued it), there's nothing for reloader to react to. Don't waste time auditing reloader annotations as the fix for this class of incident; only audit them as an orthogonal, unrelated defense-in-depth check (see Step 3).

## A missing CA is a DISTRIBUTION gap, not a rotation gap

Before assuming a rotation incident, check whether the CA was ever distributed
at all. Different problem, different fix, and the symptom is identical:
`self-signed certificate in certificate chain` / `x509: unknown authority`.

A cluster commonly has **more than one CA**: a cert-manager `selfSigned` root
for in-cluster leaves, plus an external corporate/FreeIPA root that signs the
internal ingress wildcard. If the `Bundle` only sources the first, every client
reaching a service over its **internal ingress hostname** fails, while the same
client reaching a service by ClusterIP over a leaf from the bundled CA succeeds.

That asymmetry is the diagnostic. Find a service that *does* verify and compare
issuers — same trust store, opposite outcome, decided purely by Bundle
membership. Always establish this control before changing anything.

**Domain-joined nodes do not help pods.** `ipa-client-install` puts the root in
the *host* trust store, but trust-manager mounts its ConfigMap **over**
`/etc/ssl/certs/ca-certificates.crt` in each container, replacing the node's
bundle wholesale. Never reason from "the nodes trust it" to "the pods trust it";
check what is actually mounted (`mount | grep ca-certificates`).

Confirm the gap is coverage and not staleness before writing the fix: compare
the CA in git, the live issuer object, and what the CA endpoint serves now
(`/ipa/config/ca.crt` for FreeIPA). Identical fingerprints across all three mean
nothing rotated — it was simply never added.

### Source the CA live; never paste it inline

An `inLine:` PEM blob goes stale the day the CA rotates and silently advertises
a retired anchor until a human edits git. Source it from a Secret so rotation
propagates by itself.

Two constraints make this harder than it looks:

- **trust-manager reads sources only from `--trust-namespace`** (usually
  `cert-manager`). A leaf carrying the CA in its chain but living in another
  namespace is not addressable. Check the flag on the deployment before
  planning around a Secret you cannot reach.
- **Verify a candidate Secret's contents, not its name.** An ACME issuer's
  account Secret holds only `tls.key` — zero certificates — despite a name that
  reads like a CA. Decode and `openssl x509 -subject` every candidate.

When no usable Secret exists in the trust namespace, mint a leaf whose only job
is to carry the chain: a `Certificate` from the same issuer as the real ingress
cert, that nothing ever connects to. cert-manager renews it, the renewed chain
carries whatever CA is current, trust-manager republishes.

### `filterNonCACerts` is mandatory with that pattern

A leaf `tls.crt` is a chain: leaf **then** CA. Feeding it in raw publishes a
short-lived server certificate as a cluster-wide trust anchor. The Helm value
`filterNonCACerts.enabled: true` renders `--filter-non-ca-certs=true` and drops
anything without `isCA` in basicConstraints. **It defaults to `false`.**

Prove it rather than trusting the changelog: apply a throwaway `Bundle` over the
same Secret targeting one namespace, count the published certs, and check the
leaf is absent. Without the flag both certificates appear.

### Verify after sync

Count before and after — exactly +1 — and confirm which one landed:

```bash
kubectl get cm <bundle-name> -n <any-ns> -o jsonpath='{.data.<key>}' > /tmp/b.pem
# split on BEGIN CERTIFICATE, openssl x509 -subject each: root present, leaf absent
```

Then re-run the original failing request with no `--insecure`.

**Testing a candidate bundle by hand needs a newline between concatenated
files.** The mounted bundle has no trailing newline, so a naive
`cat bundle.pem ca.pem > candidate.pem` welds the last `-----END CERTIFICATE-----`
to the next `-----BEGIN` and Python fails with `ssl.SSLError: [X509] PEM lib`.
trust-manager itself normalises this; only the manual check trips on it.

### ACME issuance profile constrains the key algorithm

A FreeIPA/Dogtag ACME endpoint is RSA-only. An ECDSA CSR clears the DNS01
challenge and then dies at finalize with
`500 Unable to generate certificate: Key Type RSA Not Matched`, leaving the
Order wedged in `processing` — easy to misread as a solver problem. Match
`privateKey.algorithm` to what an existing working certificate from that same
issuer actually uses (`openssl x509 -text | grep "Public Key Algorithm"`),
rather than to a house default.

## Step 1 — Diagnose: confirm it's actually a CA/leaf mismatch

```bash
# Get the leaf's embedded CA fingerprint and the leaf's own issuer/subject/dates
kubectl get secret <leaf-secret> -n <ns> -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -issuer -subject -dates -fingerprint

# Get the CURRENT CA's fingerprint from its own secret
kubectl get secret <ca-secret> -n <ca-ns> -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -fingerprint -dates

# Compare. Mismatch = confirmed cascading-reissue gap.
kubectl get certificate <leaf-cert-name> -n <ns> -o yaml   # check issuerRef, lastTransitionTime vs CA's own renewal time
```

## Step 2 — Fix the root cause: make the CA rotate rarely (cheapest, most durable)

The actual lever is the CA `Certificate`'s own `spec.duration`/`renewBefore` — if it has none set, cert-manager defaults to **90 days**, which is far too short for a root CA and guarantees you'll hit this gap repeatedly. Fix:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cluster-selfsigned-ca
spec:
  isCA: true
  duration: 262800h   # 30 years
  renewBefore: 8760h  # renew 1y before expiry — huge margin for leaves to catch up naturally
  privateKey:
    algorithm: ECDSA
    size: 256
```

Rule of thumb from upstream discussion: CA duration should be **at least 2x** the leaf cert duration, so natural leaf renewal cycles always land inside a single CA lifetime — no forced/manual reissue ever needed. A long-lived CA with rare rotation makes the whole cascading-reissue gap moot in practice.

Check first whether the CA `Certificate` has `duration`/`renewBefore` set at all before assuming any other cause — an unset duration silently defaulting to 90 days is a very easy thing to miss and was the actual root cause the one time this was chased down.

**Applying this spec change alone does NOT reissue the CA.** cert-manager only detects a `duration`/`renewBefore` mismatch against the *latest CertificateRequest* — if none is pending, the change sits in `spec` with `status.notAfter`/`revision` completely unchanged (confirmed: patched `duration` to 30y, status still showed the old 90-day `notAfter` and unchanged `revision` until reissue was forced separately). Don't report the fix as "done" until you've confirmed `status.notAfter` actually moved.

**CRITICAL — forcing reissue of a self-signed CA regenerates its private key, despite `rotationPolicy: Never`.** This was verified directly: forcing an `Issuing=True` status patch on a CA `Certificate` backed by a `selfSigned` issuer produced a **new Subject Key Identifier** (new keypair), not just a new validity window with the same key. `rotationPolicy: Never` governs *scheduled* renewals of a leaf against its issuing CA — it does not protect a root CA's own key when *you* force its reissuance via the selfSigned issuer, because the selfSigned issuer has no "same key, new cert" path the way a real external/intermediate CA would. Practical consequence: forcing a CA reissue **immediately breaks every leaf certificate** already signed by that CA (AKI/SKI mismatch), the instant the patch lands — not eventually, not on next natural renewal.

So the correct sequence when you must force a CA `Certificate` to pick up a spec change:
1. **Before** forcing anything, enumerate every leaf `Certificate` that uses that `ClusterIssuer`/`Issuer`: `kubectl get certificate -A -o json | jq '.items[] | select(.spec.issuerRef.name=="<ca-issuer-name>") | .metadata.namespace + "/" + .metadata.name'`. This tells you the actual blast radius — it may be just one leaf (small) or dozens (plan a maintenance window instead of forcing live).
2. Force the CA reissue (status-subresource patch, Step 3 method 1).
3. Immediately force-reissue (or delete-secret) **every leaf** found in step 1 too — the CA's new key means they all need re-signing to restore trust, right now, not "eventually via natural renewal".
4. Restart/verify every consumer, same as any cascading-reissue incident.

If the CA has zero or very few leaves depending on it directly (e.g. it only signs one internal service's cert, with most other trust coming through trust-manager's `Bundle` distribution instead), the blast radius is small and this is a two-minute fix. Check before assuming either way.

## Step 3 — If you must force reissue now (incident response)

Two ways, ranked by RBAC blast radius:

1. **Preferred, minimal RBAC** — patch the `Certificate`'s status subresource the same way `cmctl renew` does internally (`certificates/status: patch`, no `secrets: delete` needed):
   ```bash
   cmctl renew <cert-name> -n <ns>          # if cmctl is available
   # or manually: set condition Issuing=True on Certificate.status via the API — a plain
   # `kubectl annotate certificate ... force` does NOT work: metadata annotations don't bump
   # .metadata.generation and are filtered out by the trigger controller's predicate.
   ```
2. **Blunt, works everywhere, higher privilege** — delete the leaf Secret; cert-manager detects it's missing and reissues immediately:
   ```bash
   kubectl delete secret <leaf-secret> -n <ns>
   kubectl get certificate <leaf-cert-name> -n <ns> -w   # watch until Ready again
   openssl verify -CAfile <new-ca.crt> <new-leaf.crt>    # confirm it chains to current CA
   kubectl rollout restart deployment/<consumer> -n <ns> # only needed if that consumer lacks reloader
   ```
   Requires `secrets: delete` RBAC — used as the practical emergency path when annotate-based renewal was blocked.

After forcing reissue, check whether reloader auto-restarted every consumer, or whether some Deployment/StatefulSet is missing the `reloader.stakater.com/auto: "true"` annotation (or equivalent pod annotation depending on the chart) — that's a legitimate, independent gap worth closing even though it wasn't the root cause here.

## Pitfalls

- Don't chase reloader config first when the symptom is `x509: unknown authority` after a CA rotation — check Step 1's fingerprint comparison before assuming a reload-mechanism bug.
- `kubectl annotate certificate <name> ... renewal-flag force` is not a real trigger and can hang/fail — use `cmctl renew` or a genuine status-condition patch instead.
- Don't skip checking whether *other* apps besides the one that paged you hit the same CA-rotation gap silently (ArgoCD `OutOfSync` apps that never alerted) — enumerate all `Certificate` resources signed by the same rotated CA before declaring the incident closed.
- A CA with no `duration` set is not "using sane defaults" — 90 days is aggressive for a root CA and is the single most common root cause of this whole class of incident. Check it explicitly, don't assume someone already tuned it.
- Don't assume a `duration`/`renewBefore` spec edit alone fixed anything — verify `status.notAfter` and `status.revision` actually moved before telling the user it's resolved.
- Never force-reissue a self-signed root CA without first listing every leaf `Certificate` that trusts it. `rotationPolicy: Never` does not stop the key from changing when you force reissuance on a `selfSigned`-backed CA — it changes every time, and every dependent leaf breaks the instant it does.
